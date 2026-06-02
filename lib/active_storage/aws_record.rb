require 'time'
require 'aws-record'
require 'globalid'
require 'active_support'
require 'active_support/core_ext/object/blank'
require 'active_model'
require 'active_storage'

require 'active_storage/aws_record/version'
require 'active_storage/aws_record/configuration'
require 'active_storage/aws_record/schema'

module ActiveStorage
  # Active Storage *metadata* backend backed by Amazon DynamoDB through the
  # +aws-record+ gem. Blob bytes flow through a normal Active Storage Service
  # (Disk/S3); only blob/attachment/variant-record metadata lives in DynamoDB,
  # in a single application-provided table (Single Table Design). See PLAN.md /
  # README.md for the full design.
  module AwsRecord
    autoload :Persistence,   'active_storage/aws_record/persistence'
    autoload :Item,          'active_storage/aws_record/item'
    autoload :Attachable,    'active_storage/aws_record/attachable'
    autoload :Owner,         'active_storage/aws_record/owner'
    autoload :Relation,      'active_storage/aws_record/relation'
    autoload :Transaction,        'active_storage/aws_record/transaction'
    autoload :TransactionTooLarge, 'active_storage/aws_record/transaction'
    autoload :Blob,          'active_storage/aws_record/blob'
    autoload :Attachment,    'active_storage/aws_record/attachment'
    autoload :VariantRecord, 'active_storage/aws_record/variant_record'
    autoload :Tables,        'active_storage/aws_record/tables'

    # Eager, load-time initialization keeps the shared mutable state fiber-safe
    # under Falcon: the mutex exists before any fiber can race on the client, and
    # the config/schema objects are created up front (never via +||=+).
    @client_mutex = Mutex.new
    @config = Configuration.new
    @schema = nil
    @dynamodb_client = nil

    class << self
      # @return [Configuration] the memoized gem configuration.
      attr_reader :config

      # @return [Schema, nil] the resolved table layout (set by {.install!}).
      attr_reader :schema

      # Yields {#config} for block-style configuration.
      def configure
        yield @config
      end

      # The shared +Aws::DynamoDB::Client+ every model uses. Built lazily but
      # mutex-guarded so concurrent fibers cannot race two clients into existence.
      #
      # @return [Aws::DynamoDB::Client]
      def dynamodb_client
        @client_mutex.synchronize do
          @dynamodb_client ||= @config.client || Aws::DynamoDB::Client.new(@config.client_options)
        end
      end

      # Inject a client (tests / Railtie) and rewire the models to it.
      def dynamodb_client=(client)
        @client_mutex.synchronize { @dynamodb_client = client }
        [Blob, Attachment, VariantRecord].each do |model|
          model.configure_client(client: client) if model.respond_to?(:configure_client)
        end
        client
      end

      # Drop the memoized client/schema (tests, and the Railtie before re-boot).
      def reset!
        @client_mutex.synchronize do
          @dynamodb_client = nil
          @schema = nil
        end
      end

      # Build a +#+-separated composite key, validating every segment is present
      # (a blank segment would silently corrupt the key space). This is the gem's
      # lightweight stand-in for an app-specific +compose_key+.
      #
      # @param parts [Array<#to_s>]
      # @return [String]
      def key(*parts)
        separator = @config.separator
        parts.each do |part|
          raise ArgumentError, "key segment cannot be blank (parts: #{parts.inspect})" if part.nil? || part.to_s.empty?

          if part.to_s.include?(separator)
            raise ArgumentError, "key segment #{part.inspect} may not contain the separator #{separator.inspect} " \
              "(parts: #{parts.inspect})"
          end
        end
        parts.join(separator)
      end

      # Discover the table layout, declare the key attributes on the three models
      # (now that their DB names are known), point them at the shared client, and
      # set the table name. Idempotent; safe to call at every boot.
      def install!
        client = dynamodb_client
        Tables.ensure! if @config.manage_table
        @client_mutex.synchronize { @schema ||= Schema.discover(client, @config) }

        [Blob, Attachment, VariantRecord].each do |model|
          model.set_table_name(@config.table_name)
          define_key_attributes!(model)
          model.configure_client(client: client)
        end
      end

      # Declare +has_one_attached+ on the gem's owner entities. Must run after
      # Active Storage class indirection so the generic (non-AR) builder is used.
      # Idempotent.
      def install_attachments!
        unless Blob.respond_to?(:reflect_on_attachment) && Blob.reflect_on_attachment(:preview_image)
          Blob.has_one_attached :preview_image
        end
        unless VariantRecord.respond_to?(:reflect_on_attachment) && VariantRecord.reflect_on_attachment(:image)
          VariantRecord.has_one_attached :image
        end
      end

      private

      # Declare the table's key attributes on a model using the discovered DB
      # names. Ruby accessor names are gem-private (+dynamo_*+) so they never
      # collide with entity attributes. In Mode B the numeric range key holds a
      # constant and two extra string attributes carry the adjacency keys for the
      # GSI.
      def define_key_attributes!(model)
        return if model.hash_key # already installed in this process

        model.string_attr :dynamo_partition_key, hash_key: true, database_attribute_name: @schema.partition_attr
        if @schema.range_mode?
          model.string_attr :dynamo_range_key, range_key: true, database_attribute_name: @schema.sort_attr
        else
          model.integer_attr :dynamo_range_key, range_key: true, database_attribute_name: @schema.sort_attr
          model.string_attr :dynamo_index_partition, database_attribute_name: @schema.index_partition_attr
          model.string_attr :dynamo_index_sort, database_attribute_name: @schema.index_sort_attr
        end
      end
    end
  end
end

require 'active_storage/aws_record/railtie' if defined?(Rails::Railtie)
