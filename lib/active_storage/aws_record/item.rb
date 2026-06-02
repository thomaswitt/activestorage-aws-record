module ActiveStorage
  module AwsRecord
    # Single-table key machinery, mixed into the gem's three entities only
    # (+Blob+, +Attachment+, +VariantRecord+) — never into application owner
    # models. It turns each entity's *logical* keys into the *physical* DynamoDB
    # keys for the resolved {Schema} mode, and stamps them before a write.
    #
    # Including classes must implement +#logical_keys+ returning
    # <tt>{ h:, r:, item_id: }</tt>:
    # * +h+      — the partition adjacency key (the +ns#…#…+ string),
    # * +r+      — the sort adjacency key,
    # * +item_id+— a globally-unique id string (the base-table partition in Mode B).
    module Item
      extend ActiveSupport::Concern

      include Persistence

      class_methods do
        # @return [Schema] the resolved table layout.
        def schema
          ActiveStorage::AwsRecord.schema
        end

        # Namespaced +#+-key: prepends the configured namespace to +parts+.
        def ns_key(*parts)
          ActiveStorage::AwsRecord.key(ActiveStorage::AwsRecord.config.namespace, *parts)
        end

        # aws-record key hash (Ruby attribute symbols → values) for +find_with_opts+.
        def aws_record_key(h:, r:, item_id:)
          if schema.range_mode?
            { dynamo_partition_key: h, dynamo_range_key: r }
          else
            { dynamo_partition_key: item_id, dynamo_range_key: 0 }
          end
        end

        # Raw DynamoDB key (DB attribute names → values) for transact/raw calls.
        def physical_key(h:, r:, item_id:)
          if schema.range_mode?
            { schema.partition_attr => h, schema.sort_attr => r }
          else
            { schema.partition_attr => item_id, schema.sort_attr => 0 }
          end
        end

        # Fetch one item by logical keys (strongly consistent by default).
        # @return [Aws::Record, nil]
        def get_item(h:, r:, item_id:, consistent: true)
          find_with_opts(key: aws_record_key(h:, r:, item_id:), consistent_read: consistent)
        end
      end

      def schema
        ActiveStorage::AwsRecord.schema
      end

      def ns_key(*parts)
        self.class.ns_key(*parts)
      end

      # The raw key for this instance (DB attribute names → values).
      def physical_key
        self.class.physical_key(**logical_keys)
      end

      # Stamp the physical key attributes from this item's logical keys. Only on
      # create: a key attribute cannot be updated in DynamoDB, and re-stamping
      # would mark it dirty and break the next +update_item+.
      def stamp_physical_keys!
        return unless new_record?

        keys = logical_keys
        if schema.range_mode?
          self.dynamo_partition_key = keys[:h]
          self.dynamo_range_key = keys[:r]
        else
          self.dynamo_partition_key = keys[:item_id]
          self.dynamo_range_key = 0
          self.dynamo_index_partition = keys[:h]
          self.dynamo_index_sort = keys[:r]
        end
      end
    end
  end
end
