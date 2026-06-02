# frozen_string_literal: true

require_relative 'test_helper'

Blob = ActiveStorage::AwsRecord::Blob unless defined?(Blob)
Attachment = ActiveStorage::AwsRecord::Attachment unless defined?(Attachment)

# Covers the batched, atomic destroy path added so the generic +has_many+
# clear/replace/detach contract (which wraps grouped destroys in
# +attachment_class.transaction+) no longer deletes some attachment rows before a
# later one fails. See Transaction and Attachment#enqueue_or_destroy.
class TransactionTest < ActiveSupport::TestCase
  test 'clearing a has_many of distinct blobs deletes every row, zeroes every refcount, and defers a purge per blob' do
    widget = save_widget
    widget.photos.attach(
      { io: StringIO.new('P1'), filename: '1.txt', content_type: 'text/plain' },
      { io: StringIO.new('P2'), filename: '2.txt', content_type: 'text/plain' }
    )
    blob_ids = attachments_for(widget, 'photos').map(&:blob_id)
    assert_equal 2, blob_ids.size
    blob_ids.each { |id| assert_equal 1, Blob.find(id).attachments_count }

    # The batched (>=2) commit must still flush the deferred :purge_later for each
    # distinct blob *after* it commits.
    assert_enqueued_jobs 2, only: ActiveStorage::PurgeJob do
      widget.photos = []
      widget.save!
    end

    assert_empty attachments_for(widget, 'photos')
    # dependent: :purge_later keeps the blob rows; the refcount must hit zero.
    blob_ids.each { |id| assert_equal 0, Blob.find(id).attachments_count }
  end

  test 'clearing a has_many with the same blob attached twice coalesces the refcount update' do
    # Without coalescing this would emit two ADD ops on one blob item, which
    # DynamoDB rejects ("multiple operations on one item") -- so a clean clear
    # proves the per-blob delta is summed into a single update.
    widget = save_widget
    blob = create_blob(data: 'SHARED')
    widget.photos.attach(blob, blob)
    assert_equal 2, Blob.find(blob.id).attachments_count

    # Coalesced to one ADD -2, so it must not raise; and the one shared blob is
    # deferred for purge exactly once (flush dedupes by blob).
    assert_enqueued_jobs 1, only: ActiveStorage::PurgeJob do
      assert_nothing_raised do
        widget.photos = []
        widget.save!
      end
    end

    assert_empty attachments_for(widget, 'photos')
    assert_equal 0, Blob.find(blob.id).attachments_count
  end

  test 'buffering the same attachment row twice collapses to one idempotent delete' do
    widget = save_widget
    blob = create_blob(data: 'DEDUP')
    widget.photos.attach(blob)
    row = attachments_for(widget, 'photos').first
    assert_equal 1, Blob.find(blob.id).attachments_count

    # The same row enqueued twice (e.g. a nested purge) must de-dup to a single
    # delete + a single -1, not two ops on one item (which DynamoDB rejects), and
    # must not over-decrement the refcount.
    assert_nothing_raised do
      Attachment.transaction do
        row.delete
        row.delete
      end
    end

    assert_empty attachments_for(widget, 'photos')
    assert_equal 0, Blob.find(blob.id).attachments_count
    assert Blob.find(blob.id).persisted?
  end

  test 'an exception inside Attachment.transaction discards every buffered delete' do
    widget = save_widget
    b1 = create_blob(data: 'R1')
    b2 = create_blob(data: 'R2')
    widget.photos.attach(b1, b2)
    rows = attachments_for(widget, 'photos')
    assert_equal 2, rows.size

    assert_raises(RuntimeError) do
      Attachment.transaction do
        rows.each(&:delete)
        raise 'boom'
      end
    end

    # Nothing was written: every row and refcount is intact.
    assert_equal 2, attachments_for(widget, 'photos').size
    assert_equal 1, Blob.find(b1.id).attachments_count
    assert_equal 1, Blob.find(b2.id).attachments_count
  end

  test 'a cancelled batch commit leaves every row intact and raises RecordNotDestroyed' do
    widget = save_widget
    b1 = create_blob(data: 'C1')
    b2 = create_blob(data: 'C2')
    widget.photos.attach(b1, b2)
    rows = attachments_for(widget, 'photos')

    # Remove b2's blob item out-of-band so its guarded refcount ADD fails and
    # cancels the whole batch.
    delete_blob_row(b2.id)

    error = assert_raises(ActiveStorage::RecordNotDestroyed) do
      Attachment.transaction { rows.each(&:delete) }
    end
    assert_match(/atomically/, error.message)

    # The surviving blob's refcount and both attachment rows are untouched.
    assert_equal 2, attachments_for(widget, 'photos').size
    assert_equal 1, Blob.find(b1.id).attachments_count
  end

  test 'a non-cancellation DynamoDB error during a non-transactional destroy maps to RecordNotDestroyed' do
    widget = save_widget
    blob = create_blob(data: 'THROTTLE1')
    widget.avatar.attach(blob)
    attachment = Attachment.where(record_type: 'Widget', record_id: widget.id, name: 'avatar').first

    throttle = Aws::DynamoDB::Errors::ProvisionedThroughputExceededException.new(nil, 'throttled')
    ActiveStorage::AwsRecord.dynamodb_client.stub(:transact_write_items, ->(*, **) { raise throttle }) do
      assert_raises(ActiveStorage::RecordNotDestroyed) { attachment.destroy }
    end
  end

  test 'a non-cancellation DynamoDB error during a batched commit maps to RecordNotDestroyed and writes nothing' do
    widget = save_widget
    b1 = create_blob(data: 'THROTTLE2')
    b2 = create_blob(data: 'THROTTLE3')
    widget.photos.attach(b1, b2)
    rows = attachments_for(widget, 'photos')

    throttle = Aws::DynamoDB::Errors::ProvisionedThroughputExceededException.new(nil, 'throttled')
    ActiveStorage::AwsRecord.dynamodb_client.stub(:transact_write_items, ->(*, **) { raise throttle }) do
      assert_raises(ActiveStorage::RecordNotDestroyed) do
        Attachment.transaction { rows.each(&:delete) }
      end
    end

    assert_equal 2, attachments_for(widget, 'photos').size
    assert_equal 1, Blob.find(b1.id).attachments_count
  end

  test 'a transaction over DynamoDB\'s 100-action limit fails closed before any write' do
    widget = save_widget
    # 51 distinct blobs -> 51 deletes + 51 refcount updates = 102 > 100.
    blobs = Array.new(51) do |i|
      Blob.create_before_direct_upload!(filename: "#{i}.txt", byte_size: 1, checksum: 'x', content_type: 'text/plain')
    end
    widget.photos.attach(*blobs)
    assert_equal 51, attachments_for(widget, 'photos').size

    widget.photos = []
    assert_raises(ActiveStorage::AwsRecord::TransactionTooLarge) { widget.save! }

    # Fail-closed: not one row was deleted.
    assert_equal 51, attachments_for(widget, 'photos').size
  end

  test 'nested transactions buffer into the outermost and commit exactly once' do
    widget = save_widget
    b1 = create_blob(data: 'N1')
    b2 = create_blob(data: 'N2')
    widget.photos.attach(b1, b2)
    rows = attachments_for(widget, 'photos')

    Attachment.transaction do
      rows.first.delete
      Attachment.transaction { rows.last.delete } # joins the outer transaction
      assert_equal 2, attachments_for(widget, 'photos').size, 'nothing commits until the outer block ends'
    end

    assert_empty attachments_for(widget, 'photos')
    assert_equal 0, Blob.find(b1.id).attachments_count
    assert_equal 0, Blob.find(b2.id).attachments_count
  end

  test 'the fiber-local context is cleared after both success and failure' do
    assert_nil ActiveStorage::AwsRecord::Transaction.current

    Attachment.transaction { assert ActiveStorage::AwsRecord::Transaction.current }
    assert_nil ActiveStorage::AwsRecord::Transaction.current, 'cleared after a successful commit'

    assert_raises(RuntimeError) { Attachment.transaction { raise 'x' } }
    assert_nil ActiveStorage::AwsRecord::Transaction.current, 'cleared after a failed block'

    # A later standalone detach still works on the now-clean fiber.
    widget = save_widget
    blob = create_blob(data: 'AFTER')
    widget.avatar.attach(blob)
    widget.avatar.detach
    assert_not Widget.find(widget.id).avatar.attached?
    assert_equal 0, Blob.find(blob.id).attachments_count
  end

  test 'detach-many (Relation#delete_all) batches the deletes and keeps the blobs' do
    widget = save_widget
    b1 = create_blob(data: 'X1')
    b2 = create_blob(data: 'X2')
    widget.photos.attach(b1, b2)
    assert_equal 1, Blob.find(b1.id).attachments_count

    widget.photos.detach

    assert_empty attachments_for(widget, 'photos')
    # detach uses #delete (no purge): rows gone, refcount dropped, blobs kept.
    [b1, b2].each do |blob|
      assert_equal 0, Blob.find(blob.id).attachments_count
      assert Blob.find(blob.id).persisted?
    end
  end

  test 'detach-many coalesces the refcount when the same blob is attached twice' do
    widget = save_widget
    blob = create_blob(data: 'DUP')
    widget.photos.attach(blob, blob)
    assert_equal 2, Blob.find(blob.id).attachments_count

    assert_nothing_raised { widget.photos.detach }

    assert_empty attachments_for(widget, 'photos')
    assert_equal 0, Blob.find(blob.id).attachments_count
    assert Blob.find(blob.id).persisted?
  end

  private

  def save_widget
    Widget.new(name: 'Acme').tap(&:save!)
  end

  def attachments_for(widget, name)
    Attachment.where(record_type: 'Widget', record_id: widget.id, name: name).to_a
  end

  def delete_blob_row(blob_id)
    keys = Blob.logical_keys_for(blob_id)
    ActiveStorage::AwsRecord.dynamodb_client.delete_item(
      table_name: Blob.table_name, key: Blob.physical_key(**keys)
    )
  end
end
