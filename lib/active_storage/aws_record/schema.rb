module ActiveStorage
  module AwsRecord
    # The resolved physical layout of the single table, discovered once at boot
    # from +describe_table+ (with optional config overrides) and cached read-only
    # thereafter. Two modes, chosen by the range key's type:
    #
    # * +:range+ (range key is String "S") — the gem writes its +#+-composite
    #   adjacency keys straight into the table's (partition, sort) attributes. All
    #   reads are on the base table and strongly consistent. No GSI.
    # * +:index+ (range key is Number "N") — composite strings cannot live in a
    #   numeric range key, so each item is keyed by a unique +item_id+ plus a
    #   constant +0+ range, and the adjacency keys move to a string-keyed GSI that
    #   serves listing queries (eventually consistent). Point lookups, the
    #   refcount, and the foreign-key guard stay on the base table (strong).
    #
    # The partition key must be String in both modes (it stores +item_id+/key
    # strings); a numeric partition key is rejected.
    class Schema
      # DynamoDB attribute names the gem stores for its own logical attributes.
      # Detected key attributes must not collide with these (see {.guard_names!}).
      RESERVED_ATTRIBUTE_NAMES = %w[
        as_id as_key as_filename as_content_type as_byte_size as_checksum
        as_metadata as_service_name as_created_at as_attachments_count
        as_record_type as_record_id as_name as_blob_id as_variation_digest
        as_entity
      ].freeze

      attr_reader :mode, :partition_attr, :sort_attr,
                  :index_name, :index_partition_attr, :index_sort_attr

      # Inspect the live table and resolve the layout.
      #
      # @param client [Aws::DynamoDB::Client]
      # @param config [Configuration]
      # @return [Schema]
      # @raise [ConfigurationError] when the table cannot be adapted.
      def self.discover(client, config)
        table = describe(client, config.table_name)
        new(table, config)
      end

      def self.describe(client, table_name)
        client.describe_table(table_name: table_name).table
      rescue Aws::DynamoDB::Errors::ResourceNotFoundException
        raise ConfigurationError, "DynamoDB table #{table_name.inspect} does not exist. " \
          'Create it first, or set config.manage_table = true in development.'
      end

      def initialize(table, config)
        types = table.attribute_definitions.each_with_object({}) { |d, h| h[d.attribute_name] = d.attribute_type }

        @partition_attr = key_name(table.key_schema, 'HASH')
        @sort_attr      = key_name(table.key_schema, 'RANGE')

        validate!(types)

        case types[@sort_attr]
        when 'S'
          @mode = :range
        when 'N'
          @mode = :index
          resolve_index!(table, config, types)
        else
          raise ConfigurationError, "Range key #{@sort_attr.inspect} must be type String (S) or Number (N), " \
            "got #{types[@sort_attr].inspect}."
        end

        self.class.guard_names!(self)
      end

      # @return [Boolean] true in Mode A (string range key, base-table adjacency).
      def range_mode? = @mode == :range

      # @return [Boolean] true in Mode B (numeric range key, GSI adjacency).
      def index_mode? = @mode == :index

      private

      def key_name(key_schema, type)
        key_schema.find { it.key_type == type }&.attribute_name
      end

      def validate!(types)
        raise ConfigurationError, 'Table has no partition key' unless @partition_attr
        raise ConfigurationError, "Table #{@partition_attr.inspect} has no range key; a " \
          'composite (partition + sort) key is required.' unless @sort_attr

        partition_type = types[@partition_attr]
        if partition_type && partition_type != 'S'
          raise ConfigurationError, "Partition key #{@partition_attr.inspect} must be type String (S), " \
            "got #{partition_type.inspect}."
        end
      end

      # Mode B needs a string-keyed GSI carrying the adjacency keys. Locate it by
      # the configured name and adopt its actual key attribute names. Absent on an
      # app-managed table → tell the operator exactly what to add rather than
      # silently mutating their indexes. The GSI must have a (String, String) key
      # and project ALL.
      def resolve_index!(table, config, types)
        @index_name = config.index_name
        gsi = (table.global_secondary_indexes || []).find { it.index_name == @index_name }
        unless gsi
          raise ConfigurationError, "Range key #{@sort_attr.inspect} is numeric (N), so a string-keyed " \
            "GSI named #{@index_name.inspect} is required (a String partition + String sort key, " \
            'projection ALL). Add it to the table, or set config.manage_table = true in development.'
        end

        @index_partition_attr = key_name(gsi.key_schema, 'HASH')
        @index_sort_attr      = key_name(gsi.key_schema, 'RANGE')

        validate_index!(gsi, types)
      end

      def validate_index!(gsi, types)
        unless @index_partition_attr && @index_sort_attr
          raise ConfigurationError, "GSI #{@index_name.inspect} must have both a partition and a sort key."
        end

        [@index_partition_attr, @index_sort_attr].each do |attr|
          type = types[attr]
          if type && type != 'S'
            raise ConfigurationError, "GSI #{@index_name.inspect} key #{attr.inspect} must be type String (S), " \
              "got #{type.inspect}."
          end
        end

        projection = gsi.projection&.projection_type
        if projection && projection != 'ALL'
          raise ConfigurationError, "GSI #{@index_name.inspect} must project ALL attributes (got #{projection.inspect})."
        end
      end

      # Reject a table whose key (or index key) attribute names collide with the
      # gem's stored attributes — aws-record cannot map two attributes to one
      # DynamoDB name.
      def self.guard_names!(schema)
        names = [schema.partition_attr, schema.sort_attr,
                 schema.index_partition_attr, schema.index_sort_attr,].compact
        clash = names & RESERVED_ATTRIBUTE_NAMES
        unless clash.empty?
          raise ConfigurationError, "Key attribute name(s) #{clash.inspect} collide with attributes the gem " \
            'stores. Use different key attribute names for this table.'
        end
      end
    end
  end
end
