require_relative 'support/dynamo_setup'

require 'minitest/autorun'
require 'active_job/test_helper'

DynamoSetup.boot!

# A real aws-record attachment owner, defined after boot so class indirection
# points at the gem's classes when the attachments are declared. It keeps its own
# table (owners are the application's concern); the gem's single table holds only
# blob/attachment/variant-record metadata.
class Widget
  include Aws::Record
  include ActiveStorage::AwsRecord::Owner

  set_table_name 'asar_test_widgets'
  string_attr :id, hash_key: true
  string_attr :name

  validates :name, presence: true

  has_one_attached :avatar
  has_one_attached :icon, dependent: :purge
  has_one_attached :cover, dependent: false
  has_one_attached :doc_with_immediate_analysis, analyze: :immediately
  has_one_attached :doc_with_lazy_analysis, analyze: :lazily
  has_many_attached :photos
  has_many_attached :favorites, dependent: :purge

  def initialize(attrs = {})
    super
    self.id ||= SecureRandom.uuid
  end
end

# A *bring-your-own-persistence* owner: an aws-record model with its own
# +save+/+destroy+ that uses {Attachable} (NOT {Owner}), so the gem does not take
# over persistence. The save/destroy run Active Storage's callback chains via the
# Attachable helpers — the path an app with its own BaseModel would take.
class Gadget
  include Aws::Record
  include ActiveStorage::AwsRecord::Attachable

  set_table_name 'asar_test_gadgets'
  string_attr :id, hash_key: true
  string_attr :name

  validates :name, presence: true

  has_one_attached :badge
  has_many_attached :parts

  def initialize(attrs = {})
    super
    self.id ||= SecureRandom.uuid
  end

  # The app owns persistence; it must run the Active Storage callback chains.
  def save(opts = {})
    run_attachment_save { super(opts) }
  end

  def destroy(opts = {})
    run_attachment_destroy { delete!(opts) if persisted? }
  end
end

module OwnerTables
  module_function

  def ensure!
    %w[asar_test_widgets asar_test_gadgets].each { |name| create(name) }
  end

  def create(name)
    client = ActiveStorage::AwsRecord.dynamodb_client
    client.describe_table(table_name: name)
  rescue Aws::DynamoDB::Errors::ResourceNotFoundException
    client.create_table(
      table_name: name,
      attribute_definitions: [{ attribute_name: 'id', attribute_type: 'S' }],
      key_schema: [{ attribute_name: 'id', key_type: 'HASH' }],
      billing_mode: 'PAY_PER_REQUEST'
    )
    client.wait_until(:table_exists, table_name: name)
  end
end

OwnerTables.ensure!

# App-owned aws-record owner models persist to their own tables, so point their
# aws-record client at the same DynamoDB Local endpoint the gem uses (an app would
# configure this in its own initializer / BaseModel).
[Widget, Gadget].each { |model| model.configure_client(client: ActiveStorage::AwsRecord.dynamodb_client) }

class ActiveSupport::TestCase
  include ActiveJob::TestHelper

  # Clear all rows between tests for isolation (DynamoDB Local is fast).
  setup do
    clear_table(ActiveStorage::AwsRecord.config.table_name)
    clear_table('asar_test_widgets')
    clear_table('asar_test_gadgets')
  end

  private

  def clear_table(name)
    client = ActiveStorage::AwsRecord.dynamodb_client
    desc = client.describe_table(table_name: name).table
    key_attrs = desc.key_schema.map(&:attribute_name)
    items = client.scan(table_name: name).items
    items.each do |item|
      key = key_attrs.each_with_object({}) { |k, h| h[k] = item[k] }
      client.delete_item(table_name: name, key: key)
    end
  rescue Aws::DynamoDB::Errors::ResourceNotFoundException
    nil
  end

  def create_blob(data: 'Hello!', filename: 'hello.txt', content_type: 'text/plain')
    ActiveStorage::AwsRecord::Blob.create_and_upload!(
      io: StringIO.new(data), filename: filename, content_type: content_type, identify: false
    )
  end
end
