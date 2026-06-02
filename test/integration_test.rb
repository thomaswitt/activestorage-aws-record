# frozen_string_literal: true

require_relative 'test_helper'

Blob = ActiveStorage::AwsRecord::Blob unless defined?(Blob)
Attachment = ActiveStorage::AwsRecord::Attachment unless defined?(Attachment)

class IntegrationTest < ActiveSupport::TestCase
  test 'has_one attach, download, and reload from DynamoDB' do
    widget = Widget.new(name: 'Acme')
    widget.save!
    widget.avatar.attach(io: StringIO.new('AV'), filename: 'a.txt', content_type: 'text/plain')

    assert widget.avatar.attached?
    assert_equal 'AV', widget.avatar.download
    assert widget.avatar.blob.persisted?

    reloaded = Widget.find(widget.id)
    assert reloaded.avatar.attached?
    assert_equal 'AV', reloaded.avatar.download
  end

  test 'detach keeps the blob, purge removes it' do
    widget = save_widget
    blob = attach_avatar(widget)

    widget.avatar.detach
    assert_not Widget.find(widget.id).avatar.attached?
    assert Blob.find(blob.id).persisted?

    widget.avatar.attach(blob)
    widget.avatar.purge
    assert_not Widget.find(widget.id).avatar.attached?
    assert_raises(ActiveStorage::RecordNotFound) { Blob.find(blob.id) }
  end

  test 'replacing a has_one with dependent: :purge purges the old blob' do
    widget = save_widget
    old = create_blob(data: 'OLD')
    widget.icon.attach(old)
    widget.icon.attach(create_blob(data: 'NEW'))

    assert_raises(ActiveStorage::RecordNotFound) { Blob.find(old.id) }
    assert_equal 'NEW', Widget.find(widget.id).icon.download
  end

  test 'has_many attach, order, and clear' do
    widget = save_widget
    widget.photos.attach(
      { io: StringIO.new('P1'), filename: '1.txt', content_type: 'text/plain' },
      { io: StringIO.new('P2'), filename: '2.txt', content_type: 'text/plain' }
    )
    assert_equal %w[P1 P2], Widget.find(widget.id).photos.map(&:download)

    widget.photos = []
    widget.save!
    assert_empty Widget.find(widget.id).photos
  end

  test 'owner destroy purges dependent blobs and clears attachment rows' do
    widget = save_widget
    widget.favorites.attach(
      { io: StringIO.new('F1'), filename: '1.txt', content_type: 'text/plain' },
      { io: StringIO.new('F2'), filename: '2.txt', content_type: 'text/plain' }
    )
    blob_ids = widget.favorites.map { |a| a.blob.id }

    widget.destroy

    assert_empty Attachment.where(record_type: 'Widget', record_id: widget.id).to_a
    blob_ids.each { |id| assert_raises(ActiveStorage::RecordNotFound) { Blob.find(id) } }
  end

  test 'default has_many uses purge_later and enqueues a single PurgeJob per shared blob' do
    widget = save_widget
    blob = create_blob(data: 'SHARED')
    widget.photos.attach(blob, blob) # same blob twice
    assert_equal 2, Widget.find(widget.id).photos.count

    assert_enqueued_jobs 1, only: ActiveStorage::PurgeJob do
      widget.destroy
    end
  end

  test 'aborted owner destroy keeps attachment rows and blob' do
    # Snapshot and restore the chain rather than reset_callbacks(:destroy), which
    # would also strip the generic builder's attachment-cleanup callbacks and
    # break later tests.
    saved_callbacks = Widget._destroy_callbacks
    Widget.set_callback(:destroy, :before) { throw :abort }
    begin
      widget = save_widget
      blob = attach_avatar(widget)

      assert_no_enqueued_jobs only: ActiveStorage::PurgeJob do
        widget.destroy
      end
      assert widget.persisted?
      assert Blob.find(blob.id).persisted?
      assert Widget.find(widget.id).avatar.attached?
    ensure
      Widget._destroy_callbacks = saved_callbacks
    end
  end

  test 'destroying an unsaved owner with a colliding id leaves the saved record intact' do
    victim = save_widget
    blob = create_blob(data: 'VICTIM')
    victim.icon.attach(blob)

    attacker = Widget.new(name: 'Attacker', id: victim.id)
    refute attacker.persisted?, 'attacker must be unsaved'

    assert_no_enqueued_jobs only: ActiveStorage::PurgeJob do
      refute attacker.destroy, 'destroying a never-persisted owner is a no-op'
    end

    assert Widget.find(victim.id).persisted?, 'victim row must survive the colliding-id destroy'
    assert Blob.find(blob.id).persisted?
    assert_equal 1, Attachment.where(record_type: 'Widget', record_id: victim.id, name: 'icon').to_a.size
  end

  test 'shared blob is kept until the last attachment is purged' do
    a = save_widget
    b = save_widget
    blob = create_blob(data: 'SHARED')
    a.avatar.attach(blob)
    b.avatar.attach(blob)

    a.avatar.purge
    assert Blob.find(blob.id).persisted?, 'blob still referenced by b'
    assert b.reload_avatar_attached?

    b.avatar.purge
    assert_raises(ActiveStorage::RecordNotFound) { Blob.find(blob.id) }
  end

  test 'detach (Attachment#delete) decrements the blob refcount' do
    blob = create_blob(data: 'SHARED')
    a = save_widget
    b = save_widget
    a.avatar.attach(blob)
    b.avatar.attach(blob)
    assert_equal 2, Blob.find(blob.id).attachments_count

    a.avatar.detach # uses delete, not destroy; the count must still drop
    assert_equal 1, Blob.find(blob.id).attachments_count
    assert Blob.find(blob.id).persisted?
  end

  test 'VariantRecord.create_or_find_by! flushes the queued image attachment' do
    vr_class = ActiveStorage::AwsRecord::VariantRecord
    source = create_blob(data: 'ORIG')

    vr = vr_class.create_or_find_by!(blob_id: source.id, variation_digest: 'digest-xyz') do |record|
      record.image.attach(io: StringIO.new('VARIANT-BYTES'), filename: 'v.png', content_type: 'image/png')
    end

    assert vr.persisted?
    assert vr.image.attached?, 'image attachment must be saved during create'
    assert_equal 'VARIANT-BYTES', vr.image.download

    # Reload from DynamoDB: the image attachment row + blob survive.
    reloaded = vr_class.find_by(blob_id: source.id, variation_digest: 'digest-xyz')
    assert reloaded.image.attached?
    assert_equal 'VARIANT-BYTES', reloaded.image.download

    # Second call with the same digest finds the existing record (no duplicate).
    again = vr_class.create_or_find_by!(blob_id: source.id, variation_digest: 'digest-xyz')
    assert_equal vr.id, again.id
  end

  test "blob created_at is a Time so the proxy controller's Last-Modified works" do
    blob = create_blob(data: 'TS')
    reloaded = Blob.find(blob.id)
    assert_kind_of Time, reloaded.created_at
    assert_nothing_raised { reloaded.created_at.utc.httpdate }
  end

  test 'signed_id round-trips through the blob class' do
    blob = create_blob(data: 'SIGNED')
    signed = blob.signed_id
    assert_equal blob.id, Blob.find_signed!(signed).id
  end

  test 'immediate analysis persists metadata; lazy analysis does not enqueue' do
    widget = save_widget
    widget.doc_with_immediate_analysis.attach(io: StringIO.new('DOC'), filename: 'd.txt', content_type: 'text/plain')
    assert widget.doc_with_immediate_analysis.blob.analyzed?

    assert_no_enqueued_jobs only: ActiveStorage::AnalyzeJob do
      widget.doc_with_lazy_analysis.attach(io: StringIO.new('DOC2'), filename: 'd2.txt', content_type: 'text/plain')
    end
  end

  test 'direct upload create filters protected metadata' do
    blob = Blob.create_before_direct_upload!(
      filename: 'd.txt', byte_size: 3, checksum: 'x',
      content_type: 'text/plain',
      metadata: { 'analyzed' => true, 'identified' => true, 'composed' => true, 'custom' => { 'a' => 1 } }
    )
    refute blob.analyzed?
    assert_equal({ 'a' => 1 }, blob.custom_metadata)
  end

  private

  def save_widget
    Widget.new(name: 'Acme').tap(&:save!)
  end

  def attach_avatar(widget, data: 'AV')
    widget.avatar.attach(io: StringIO.new(data), filename: 'a.txt', content_type: 'text/plain')
    widget.avatar.blob
  end
end

# Helper used in the shared-blob test.
class Widget
  def reload_avatar_attached?
    self.class.find(id).avatar.attached?
  end
end
