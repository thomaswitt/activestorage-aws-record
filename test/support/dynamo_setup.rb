# Boots a minimal Rails application with the Active Storage engine (no Active
# Record) and this gem, pointed at a local DynamoDB endpoint with a unique,
# disposable single table. Booting a real app exercises the gem's Railtie wiring
# (including table creation + schema discovery) and lets the engine Zeitwerk-load
# Active Storage's app/models (Servable, Variant, Preview, ...). Shared by the
# smoke scripts and the test suite.

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

module DynamoSetup
  ENDPOINT = ENV.fetch('DYNAMODB_ENDPOINT', 'http://localhost:8000')

  class << self
    attr_reader :service_root, :table_name

    def boot!
      return if @booted

      @service_root = Dir.mktmpdir('asar-disk')
      @table_name = "asar_test_#{Process.pid}"
      client = Aws::DynamoDB::Client.new(
        endpoint: ENDPOINT, region: 'us-east-1',
        access_key_id: 'test', secret_access_key: 'test'
      )
      table = @table_name
      root = @service_root

      app = Class.new(Rails::Application) do
        config.eager_load = false
        config.secret_key_base = 'a' * 64
        config.active_support.to_time_preserves_timezone = :zone
        config.logger = Logger.new(IO::NULL)
        config.active_storage.service = :local
        config.active_storage.service_configurations = {
          'local' => { 'service' => 'Disk', 'root' => root },
        }
        config.active_storage.track_variants = true
        config.activestorage_aws_record.client = client
        config.activestorage_aws_record.table_name = table
        config.activestorage_aws_record.manage_table = true
      end
      Object.const_set(:ActiveStorageAwsRecordTestApp, app) unless defined?(ActiveStorageAwsRecordTestApp)
      app.initialize!

      ActiveJob::Base.queue_adapter = :test
      @booted = true
    end

    def teardown!
      ActiveStorage::AwsRecord::Tables.delete!
    rescue StandardError
      nil
    end
  end
end
