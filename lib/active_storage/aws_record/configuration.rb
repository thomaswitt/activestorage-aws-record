module ActiveStorage
  module AwsRecord
    # Raised when the gem cannot adapt to the configured DynamoDB table (e.g. a
    # numeric partition key, a missing range key, or a key-attribute name that
    # collides with one of the gem's own stored attributes).
    class ConfigurationError < StandardError; end

    # Holds the gem's settings. In a Rails app these are populated from
    # +config.activestorage_aws_record+ by the Railtie; outside Rails (the gem's
    # own test suite) they are set directly via {AwsRecord.configure}.
    #
    # The guiding principle is *assume as little as possible*: the only thing the
    # gem truly needs is the +table_name+. The partition/sort key attribute names
    # and types are discovered from the live table at boot (see {Schema}); set
    # {#partition_key}/{#sort_key} only to override that discovery.
    class Configuration
      # Name of the single DynamoDB table that holds every Active Storage item
      # (blob, attachment, and variant-record metadata). Single Table Design: the
      # gem never creates entity-specific tables. The partition/sort key attribute
      # names and types are auto-detected from this table at boot (see {Schema}).
      attr_accessor :table_name

      # First segment of every key the gem writes, isolating Active Storage items
      # from the application's own items in the shared table. Make it unique if
      # the default ("ActiveStorage") could collide with application keys.
      attr_accessor :namespace

      # Delimiter between key segments (the "#" pattern). Must not appear in a
      # +record_type+, +record_id+, or attachment +name+.
      attr_accessor :separator

      # Hash of options forwarded to +Aws::DynamoDB::Client.new+ (e.g. +:region+,
      # +:endpoint+, +:credentials+). An +:endpoint+ of "http://localhost:8000"
      # targets DynamoDB Local.
      attr_accessor :client_options

      # An explicit +Aws::DynamoDB::Client+. When set it is used as-is and
      # +client_options+ is ignored. Handy for tests and dependency injection.
      attr_accessor :client

      # When +true+, the gem will create the table (and, in Mode B, the index) if
      # missing. Defaults to +false+: production tables are application-managed.
      attr_accessor :manage_table

      # Name of the string-keyed GSI used only when the table's range key is
      # numeric (Mode B); identifies which GSI carries the adjacency keys when a
      # table has several. Its key attribute names are auto-detected. Ignored in
      # Mode A (string range key, no GSI).
      attr_accessor :index_name

      def initialize
        @table_name = 'active_storage'
        @namespace = 'ActiveStorage'
        @separator = '#'
        @client_options = {}
        @client = nil
        @manage_table = false
        @index_name = 'active_storage_index'
      end
    end
  end
end
