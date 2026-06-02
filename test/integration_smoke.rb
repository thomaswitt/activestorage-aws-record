# frozen_string_literal: true

# End-to-end check through Active Storage's generic owner path (has_one /
# has_many attached) with a real aws-record owner model.
# Run: bundle exec ruby test/integration_smoke.rb

require_relative 'support/dynamo_setup'
DynamoSetup.boot!

# Run purge_later/analyze jobs synchronously so the smoke can assert end state.
ActiveJob::Base.queue_adapter = :inline

# Owner model — defined after boot so class indirection points at the gem's
# classes when has_one_attached/has_many_attached run.
class Widget
  include Aws::Record
  include ActiveStorage::AwsRecord::Owner

  set_table_name 'asar_test_widgets'
  string_attr :id, hash_key: true
  string_attr :name

  has_one_attached :avatar
  has_many_attached :photos

  def initialize(attrs = {})
    super
    self.id ||= SecureRandom.uuid
  end
end

# Owner table.
client = ActiveStorage::AwsRecord.dynamodb_client
begin
  client.delete_table(table_name: 'asar_test_widgets')
  client.wait_until(:table_not_exists, table_name: 'asar_test_widgets')
rescue Aws::DynamoDB::Errors::ResourceNotFoundException
end
client.create_table(
  table_name: 'asar_test_widgets',
  attribute_definitions: [{ attribute_name: 'id', attribute_type: 'S' }],
  key_schema: [{ attribute_name: 'id', key_type: 'HASH' }],
  billing_mode: 'PAY_PER_REQUEST'
)
client.wait_until(:table_exists, table_name: 'asar_test_widgets')

def check(label)
  ok = yield
  puts "#{ok ? '  ok' : 'FAIL'}  #{label}"
  raise "FAILED: #{label}" unless ok
end

begin
  w = Widget.new(name: 'Acme')
  w.save!
  check('owner persisted') { w.persisted? }

  w.avatar.attach(io: StringIO.new('AV'), filename: 'a.txt', content_type: 'text/plain')
  check('has_one attached') { w.avatar.attached? }
  check('has_one download') { w.avatar.download == 'AV' }
  check('has_one blob persisted') { w.avatar.blob.persisted? }

  # Re-find the owner and read the attachment fresh (strong owner query).
  again = Widget.find(w.id)
  check('attachment survives reload') { again.avatar.attached? && again.avatar.download == 'AV' }

  avatar_blob = w.avatar.blob
  w.avatar.detach
  check('detach clears attachment') { !Widget.find(w.id).avatar.attached? }
  check('detach keeps blob') { ActiveStorage::AwsRecord::Blob.find(avatar_blob.id).persisted? }

  # has_many
  w.photos.attach(
    { io: StringIO.new('P1'), filename: 'p1.txt', content_type: 'text/plain' },
    { io: StringIO.new('P2'), filename: 'p2.txt', content_type: 'text/plain' }
  )
  check('has_many count') { Widget.find(w.id).photos.count == 2 }
  check('has_many downloads') { Widget.find(w.id).photos.map(&:download).sort == %w[P1 P2] }

  # dependent purge on owner destroy
  photo_blob_ids = w.photos.map { |a| a.blob.id }
  w.destroy
  check('owner destroyed') { !w.persisted? }
  check('attachments cleared on destroy') do
    ActiveStorage::AwsRecord::Attachment.where(record_type: 'Widget', record_id: w.id).to_a.empty?
  end
  check('dependent blobs purged') do
    photo_blob_ids.all? do
      ActiveStorage::AwsRecord::Blob.find(_1)
      false
    rescue ActiveStorage::RecordNotFound
      true
    end
  end

  puts "\nINTEGRATION SMOKE PASSED"
ensure
  client.delete_table(table_name: 'asar_test_widgets') rescue nil
  DynamoSetup.teardown!
end
