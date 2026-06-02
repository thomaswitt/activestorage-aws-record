# frozen_string_literal: true

# Quick end-to-end smoke check of the DynamoDB persistence layer + refcount.
# Run: bundle exec ruby test/smoke.rb

require_relative 'support/dynamo_setup'

DynamoSetup.boot!

Blob = ActiveStorage::AwsRecord::Blob
Attachment = ActiveStorage::AwsRecord::Attachment

def check(label)
  ok = yield
  puts "#{ok ? '  ok' : 'FAIL'}  #{label}"
  raise "FAILED: #{label}" unless ok
end

begin
  blob = Blob.create_and_upload!(io: StringIO.new('hello world'), filename: 'hello.txt', content_type: 'text/plain', identify: false)
  check('blob persisted') { blob.persisted? }
  check('blob find round-trip') { Blob.find(blob.id).id == blob.id }
  check('blob download') { blob.download == 'hello world' }
  check('blob == reloaded') { Blob.find(blob.id) == blob }
  check('attachments_count starts 0') { Blob.find(blob.id).attachments_count == 0 }

  # A bare owner stand-in: anything with a polymorphic id works for the join row.
  att = Attachment.new(record_type: 'Widget', record_id: '42', name: 'avatar', blob: blob)
  att.save!
  check('attachment persisted') { att.persisted? }
  check('refcount incremented') { Blob.find(blob.id).attachments_count == 1 }

  found = Attachment.find_by(record_type: 'Widget', record_id: '42', name: 'avatar')
  check('attachment find_by') { found && found.blob_id == blob.id }
  check('Blob#attachments unsupported on persisted blob (no reverse index)') do
    blob.attachments.to_a
    false
  rescue ActiveStorage::QueryNotSupported
    true
  end

  check('FK guard blocks shared-blob purge') do
    Blob.find(blob.id).purge # count=1 -> ForeignKeyViolation rescued -> kept
    Blob.find(blob.id).attachments_count == 1
  end

  att.destroy
  check('refcount decremented') { Blob.find(blob.id).attachments_count == 0 }
  check('attachment gone') { Attachment.find_by(record_type: 'Widget', record_id: '42', name: 'avatar').nil? }

  reloaded = Blob.find(blob.id)
  reloaded.purge
  check('blob purged after count 0') do
    Blob.find(blob.id)
    false
  rescue ActiveStorage::RecordNotFound
    true
  end

  puts "\nSMOKE PASSED"
ensure
  DynamoSetup.teardown!
end
