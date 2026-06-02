# Mode B smoke: the table's range key is NUMERIC, so the gem must auto-detect
# that, route adjacency through the string-keyed GSI, and keep the refcount /
# foreign-key guard on the base table. Run in its own process (key attributes are
# declared once per process). Run: bundle exec ruby test/mode_b_smoke.rb

require 'securerandom'
require 'tmpdir'
require 'logger'
require 'stringio'

require 'rails'
require 'active_model/railtie'
require 'active_job/railtie'
require 'action_controller/railtie'
require 'active_storage/engine'

require 'aws-sdk-dynamodb'
require 'activestorage-aws-record'

ENDPOINT = ENV.fetch('DYNAMODB_ENDPOINT', 'http://localhost:8000')
TABLE = "asar_modeb_#{Process.pid}"
INDEX = 'active_storage_index'

client = Aws::DynamoDB::Client.new(
  endpoint: ENDPOINT, region: 'us-east-1', access_key_id: 'test', secret_access_key: 'test'
)

# A single table with a NUMERIC range key (`version`) — incompatible with the
# #-composite strings — plus a string-keyed GSI carrying the adjacency keys.
client.delete_table(table_name: TABLE) rescue nil
client.create_table(
  table_name: TABLE,
  attribute_definitions: [
    { attribute_name: 'hash_key', attribute_type: 'S' },
    { attribute_name: 'version', attribute_type: 'N' },
    { attribute_name: 'as_index_pk', attribute_type: 'S' },
    { attribute_name: 'as_index_sk', attribute_type: 'S' },
  ],
  key_schema: [
    { attribute_name: 'hash_key', key_type: 'HASH' },
    { attribute_name: 'version', key_type: 'RANGE' },
  ],
  global_secondary_indexes: [
    {
      index_name: INDEX,
      key_schema: [
        { attribute_name: 'as_index_pk', key_type: 'HASH' },
        { attribute_name: 'as_index_sk', key_type: 'RANGE' },
      ],
      projection: { projection_type: 'ALL' },
    },
  ],
  billing_mode: 'PAY_PER_REQUEST'
)
client.wait_until(:table_exists, table_name: TABLE)

root = Dir.mktmpdir('asar-modeb')
app = Class.new(Rails::Application) do
  config.eager_load = false
  config.secret_key_base = 'a' * 64
  config.active_support.to_time_preserves_timezone = :zone
  config.logger = Logger.new(IO::NULL)
  config.active_storage.service = :local
  config.active_storage.service_configurations = { 'local' => { 'service' => 'Disk', 'root' => root } }
  config.active_storage.track_variants = true
  config.activestorage_aws_record.client = client
  config.activestorage_aws_record.table_name = TABLE
end
Object.const_set(:ModeBApp, app)
app.initialize!
ActiveJob::Base.queue_adapter = :inline

AR = ActiveStorage::AwsRecord
Blob = AR::Blob
Attachment = AR::Attachment
VariantRecord = AR::VariantRecord

def check(label)
  ok = yield
  puts "#{ok ? '  ok' : 'FAIL'}  #{label}"
  raise "FAILED: #{label}" unless ok
end

begin
  check('schema detected Mode B (numeric range → index)') { AR.schema.index_mode? }
  check('discovered GSI name') { AR.schema.index_name == INDEX }
  check('discovered base keys') { AR.schema.partition_attr == 'hash_key' && AR.schema.sort_attr == 'version' }

  blob = Blob.create_and_upload!(io: StringIO.new('hi mode b'), filename: 'b.txt', content_type: 'text/plain', identify: false)
  check('blob persisted') { blob.persisted? }
  check('blob find round-trip (base GetItem)') { Blob.find(blob.id).id == blob.id }
  check('blob download') { blob.download == 'hi mode b' }
  check('attachments_count starts 0') { Blob.find(blob.id).attachments_count == 0 }

  att = Attachment.new(record_type: 'Widget', record_id: '7', name: 'avatar', blob: blob)
  att.save!
  check('attachment persisted') { att.persisted? }
  check('refcount incremented (base UpdateItem)') { Blob.find(blob.id).attachments_count == 1 }

  # Owner→attachment listing goes through the GSI in Mode B.
  found = Attachment.find_by(record_type: 'Widget', record_id: '7', name: 'avatar')
  check('attachment find_by via GSI') { found && found.blob_id == blob.id }

  check('FK guard blocks shared-blob purge') do
    Blob.find(blob.id).purge
    Blob.find(blob.id).attachments_count == 1
  end

  # Variant record co-located logically; base GetItem by item_id, sweep via GSI.
  vr = VariantRecord.create_or_find_by!(blob_id: blob.id, variation_digest: 'digest123')
  check('variant persisted') { vr.persisted? }
  check('variant find_by (base GetItem)') { VariantRecord.find_by(blob_id: blob.id, variation_digest: 'digest123')&.variation_digest == 'digest123' }
  check('variant sweep via GSI') { VariantRecord.where_blob(blob.id).map(&:variation_digest) == ['digest123'] }

  att.destroy
  check('refcount decremented') { Blob.find(blob.id).attachments_count == 0 }
  check('attachment gone') { Attachment.find_by(record_type: 'Widget', record_id: '7', name: 'avatar').nil? }

  Blob.find(blob.id).purge
  check('blob purged after count 0') do
    Blob.find(blob.id)
    false
  rescue ActiveStorage::RecordNotFound
    true
  end
  check('variants swept on blob purge') { VariantRecord.where_blob(blob.id).empty? }

  puts "\nMODE B SMOKE PASSED"
ensure
  client.delete_table(table_name: TABLE) rescue nil
end
