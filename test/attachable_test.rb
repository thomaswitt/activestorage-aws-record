# frozen_string_literal: true

require_relative 'test_helper'

Blob = ActiveStorage::AwsRecord::Blob unless defined?(Blob)
Attachment = ActiveStorage::AwsRecord::Attachment unless defined?(Attachment)

# Covers the *bring-your-own-persistence* owner path: a model that keeps its own
# save/destroy and includes {Attachable} (not {Owner}), plus the Owner refactor
# that fixes the save!/save double-callback. See the Gadget model in test_helper.
class AttachableTest < ActiveSupport::TestCase
  test 'Attachable does not take over the host save/destroy' do
    assert_equal Gadget, Gadget.instance_method(:save).owner, 'host keeps its own #save'
    assert_equal Gadget, Gadget.instance_method(:destroy).owner, 'host keeps its own #destroy'
  end

  test 'a bring-your-own-persistence owner can attach, reload, and download (has_one)' do
    gadget = Gadget.new(name: 'G1')
    gadget.save
    gadget.badge.attach(io: StringIO.new('BADGE'), filename: 'b.txt', content_type: 'text/plain')

    assert gadget.badge.attached?
    assert_equal 'BADGE', gadget.badge.download

    reloaded = Gadget.active_storage_find(gadget.id)
    assert reloaded.badge.attached?
    assert_equal 'BADGE', reloaded.badge.download
  end

  test 'a bring-your-own-persistence owner supports has_many attach and clear' do
    gadget = Gadget.new(name: 'G2').tap(&:save)
    gadget.parts.attach(
      { io: StringIO.new('P1'), filename: '1.txt', content_type: 'text/plain' },
      { io: StringIO.new('P2'), filename: '2.txt', content_type: 'text/plain' }
    )
    assert_equal %w[P1 P2], Gadget.active_storage_find(gadget.id).parts.map(&:download)

    gadget.parts = []
    gadget.save
    assert_empty Gadget.active_storage_find(gadget.id).parts
  end

  test 'destroying a bring-your-own-persistence owner cleans up its attachment rows' do
    gadget = Gadget.new(name: 'G3').tap(&:save)
    gadget.badge.attach(io: StringIO.new('X'), filename: 'x.txt', content_type: 'text/plain')
    assert_equal 1, attachments_for(gadget, 'badge').size

    gadget.destroy
    assert_empty attachments_for(gadget, 'badge')
  end

  test 'Attachment#record resolves a BYO owner through the active_storage_find hook' do
    gadget = Gadget.new(name: 'G4').tap(&:save)
    gadget.badge.attach(io: StringIO.new('R'), filename: 'r.txt', content_type: 'text/plain')
    attachment = attachments_for(gadget, 'badge').first

    assert_kind_of Gadget, attachment.record
    assert_equal gadget.id, attachment.record.id
  end

  test 'active_storage_find raises RecordNotFound for a missing owner' do
    assert_raises(ActiveStorage::RecordNotFound) { Gadget.active_storage_find('nope') }
  end

  test 'gem entity owners resolve via their composite-key find, not the find_with_opts adapter' do
    # Blob and VariantRecord include Owner -> Attachable, so they inherit
    # active_storage_find; it MUST delegate to their own composite-key #find,
    # because find_with_opts(hash_key => id) cannot address the ns#...#id key.
    blob = create_blob(data: 'ENTITY-OWNER')
    assert_equal blob.id, ActiveStorage::AwsRecord::Blob.active_storage_find(blob.id).id

    vr = ActiveStorage::AwsRecord::VariantRecord.create_or_find_by!(blob_id: blob.id, variation_digest: 'd1')
    assert_equal vr.id, ActiveStorage::AwsRecord::VariantRecord.active_storage_find(vr.id).id
  end

  test 'Attachable bridges changed? to aws-record dirty? without clobbering the host' do
    gadget = Gadget.new(name: 'G5')
    assert gadget.changed?, 'a new, dirty record is changed?'
    gadget.save
    assert_not Gadget.active_storage_find(gadget.id).changed?, 'a freshly loaded record is not changed?'
  end

  # The Owner (greenfield) path: save! must run the :save chain exactly once.
  test 'Owner#save! runs the :save callbacks exactly once (no double-callback)' do
    saved_callbacks = Widget._save_callbacks
    runs = 0
    Widget.set_callback(:save, :after) { runs += 1 }

    Widget.new(name: 'CB').save!
    assert_equal 1, runs, 'save! must run the :save chain once, not twice'
  ensure
    Widget._save_callbacks = saved_callbacks
  end

  test 'Owner#save! still maps a before_save abort to RecordNotSaved' do
    saved_callbacks = Widget._save_callbacks
    Widget.set_callback(:save, :before) { throw :abort }

    assert_raises(ActiveStorage::RecordNotSaved) { Widget.new(name: 'Halt').save! }
  ensure
    Widget._save_callbacks = saved_callbacks
  end

  private

  def attachments_for(owner, name)
    Attachment.where(
      record_type: ActiveStorage::Attached::Changes.polymorphic_name(owner),
      record_id: owner.id, name: name
    ).to_a
  end
end
