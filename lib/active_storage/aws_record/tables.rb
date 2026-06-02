module ActiveStorage
  module AwsRecord
    # Creates / deletes the gem's single DynamoDB table. Intended for development
    # and tests (gated by +config.manage_table+); production tables are managed by
    # the application. The created table uses a String (partition, sort) key —
    # i.e. Mode A — with on-demand (PAY_PER_REQUEST) billing and no GSI. Point the
    # gem at an existing table (any key-attribute names; numeric range → Mode B)
    # to integrate with an app that owns its schema.
    module Tables
      module_function

      def client
        ActiveStorage::AwsRecord.dynamodb_client
      end

      def table_name
        ActiveStorage::AwsRecord.config.table_name
      end

      # Partition / sort key attribute names for a gem-created (Mode A) table.
      # Production tables are app-managed and may use any names (auto-detected).
      def partition_key
        'pk'
      end

      def sort_key
        'sk'
      end

      # Create the table if it does not already exist.
      def ensure!
        return if exist?

        create!
      end

      def exist?
        client.describe_table(table_name: table_name)
        true
      rescue Aws::DynamoDB::Errors::ResourceNotFoundException
        false
      end

      def create!
        client.create_table(
          table_name: table_name,
          attribute_definitions: [
            { attribute_name: partition_key, attribute_type: 'S' },
            { attribute_name: sort_key, attribute_type: 'S' },
          ],
          key_schema: [
            { attribute_name: partition_key, key_type: 'HASH' },
            { attribute_name: sort_key, key_type: 'RANGE' },
          ],
          billing_mode: 'PAY_PER_REQUEST'
        )
        client.wait_until(:table_exists, table_name: table_name)
      rescue Aws::DynamoDB::Errors::ResourceInUseException
        nil
      end

      def delete!
        client.delete_table(table_name: table_name)
        wait_until_gone!
      rescue Aws::DynamoDB::Errors::ResourceNotFoundException
        nil
      end

      # Drop and recreate (used by the test harness for a clean slate).
      def reset!
        delete!
        create!
      end

      def wait_until_gone!
        client.wait_until(:table_not_exists, table_name: table_name)
      rescue Aws::Waiters::Errors::WaiterFailed
        nil
      end
    end
  end
end
