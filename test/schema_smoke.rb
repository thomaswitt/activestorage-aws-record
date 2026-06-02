# Schema-discovery smoke: validates auto-detection and the guard rails, by
# describing real (disposable) tables. No app boot needed — Schema.discover takes
# a client + config directly. Run: bundle exec ruby test/schema_smoke.rb

require 'aws-sdk-dynamodb'
require 'activestorage-aws-record'

ENDPOINT = ENV.fetch('DYNAMODB_ENDPOINT', 'http://localhost:8000')
AR = ActiveStorage::AwsRecord

CLIENT = Aws::DynamoDB::Client.new(
  endpoint: ENDPOINT, region: 'us-east-1', access_key_id: 'test', secret_access_key: 'test'
)

def make_table(name, attrs, keys, gsis: nil)
  CLIENT.delete_table(table_name: name) rescue nil
  params = {
    table_name: name,
    attribute_definitions: attrs,
    key_schema: keys,
    billing_mode: 'PAY_PER_REQUEST',
  }
  params[:global_secondary_indexes] = gsis if gsis
  CLIENT.create_table(params)
  CLIENT.wait_until(:table_exists, table_name: name)
end

def discover(table)
  cfg = AR::Configuration.new
  cfg.table_name = table
  AR::Schema.discover(CLIENT, cfg)
end

def check(label)
  ok = yield
  puts "#{ok ? '  ok' : 'FAIL'}  #{label}"
  raise "FAILED: #{label}" unless ok
end

def expect_config_error(label)
  yield
  puts "FAIL  #{label} (no error raised)"
  raise "FAILED: #{label}"
rescue AR::ConfigurationError => e
  puts "  ok  #{label} (#{e.message[0, 60]}…)"
end

pid = Process.pid
tables = []
begin
  # Mode A with non-default, app-chosen String key names → auto-detected.
  t = "asar_schema_a_#{pid}"; tables << t
  make_table(t,
    [{ attribute_name: 'hash_key', attribute_type: 'S' }, { attribute_name: 'range_key', attribute_type: 'S' }],
    [{ attribute_name: 'hash_key', key_type: 'HASH' }, { attribute_name: 'range_key', key_type: 'RANGE' }])
  s = discover(t)
  check('Mode A auto-detected from custom string key names') { s.range_mode? && s.partition_attr == 'hash_key' && s.sort_attr == 'range_key' }

  # Numeric range key but NO GSI → clear error telling the operator what to add.
  t = "asar_schema_nogsi_#{pid}"; tables << t
  make_table(t,
    [{ attribute_name: 'pk', attribute_type: 'S' }, { attribute_name: 'version', attribute_type: 'N' }],
    [{ attribute_name: 'pk', key_type: 'HASH' }, { attribute_name: 'version', key_type: 'RANGE' }])
  expect_config_error('numeric range key without the GSI is rejected') { discover(t) }

  # Numeric partition key → rejected (must store key strings).
  t = "asar_schema_numpk_#{pid}"; tables << t
  make_table(t,
    [{ attribute_name: 'pk', attribute_type: 'N' }, { attribute_name: 'sk', attribute_type: 'S' }],
    [{ attribute_name: 'pk', key_type: 'HASH' }, { attribute_name: 'sk', key_type: 'RANGE' }])
  expect_config_error('numeric partition key is rejected') { discover(t) }

  # Key attribute name that collides with a stored attribute → rejected.
  t = "asar_schema_clash_#{pid}"; tables << t
  make_table(t,
    [{ attribute_name: 'as_id', attribute_type: 'S' }, { attribute_name: 'sk', attribute_type: 'S' }],
    [{ attribute_name: 'as_id', key_type: 'HASH' }, { attribute_name: 'sk', key_type: 'RANGE' }])
  expect_config_error('reserved-name collision is rejected') { discover(t) }

  puts "\nSCHEMA SMOKE PASSED"
ensure
  tables.each { |name| CLIENT.delete_table(table_name: name) rescue nil }
end
