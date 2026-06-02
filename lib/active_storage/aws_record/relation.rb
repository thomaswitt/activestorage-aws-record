module ActiveStorage
  module AwsRecord
    # A lazy relation returned by +Attachment.where+ / +Attachment.find_by+. It
    # mirrors the in-memory reference +Relation+: it collects filters/exclusions
    # and, on materialization, runs the cheapest access path for the single-table
    # layout — an owner-adjacency query — then applies residual filters,
    # exclusions, and ordering in Ruby (the attachment set for one owner+name is
    # small). Unsupported filters raise +ActiveStorage::QueryNotSupported+ rather
    # than silently scanning.
    #
    # In Mode A the query is a strongly-consistent base-table query; in Mode B it
    # runs against the string-keyed GSI (eventually consistent).
    class Relation
      include Enumerable

      def initialize(model, filters: {}, exclusions: [])
        @model = model
        @filters = filters.transform_keys(&:to_sym)
        @exclusions = exclusions
      end

      def where(attributes = nil)
        return WhereChain.new(self) if attributes.nil?

        self.class.new(@model, filters: @filters.merge(attributes), exclusions: @exclusions)
      end

      def not(attributes)
        self.class.new(@model, filters: @filters, exclusions: @exclusions + [attributes.transform_keys(&:to_sym)])
      end

      def order(*attributes)
        Ordered.new(to_a, attributes.flatten)
      end

      def find_by(attributes)
        where(attributes).first
      end

      def each(&block)
        to_a.each(&block)
      end

      def pluck(*attrs)
        to_a.map do |record|
          values = attrs.map { |a| record.public_send(a) }
          attrs.size == 1 ? values.first : values
        end
      end

      # Detach-many's bulk delete. Wrapped in the model's transaction so the rows
      # (and their coalesced blob refcount decrements) commit atomically instead
      # of one-at-a-time, matching the contract's +attachment_class.transaction+
      # expectation for grouped deletes.
      def delete_all
        records = to_a
        @model.transaction { records.each(&:delete) }
        records
      end

      def to_a
        @to_a ||= filtered(query_records)
      end

      def reload
        @to_a = nil
        self
      end
      alias_method :reset, :reload

      # Backend filtering beyond the supported keys is not available on the
      # generated collections; query the model class directly instead.
      def method_missing(name, *, &)
        raise ActiveStorage::QueryNotSupported,
          "#{name} is not supported on #{self.class.name}; query #{@model.name}.where(...) directly."
      end

      def respond_to_missing?(*)
        false
      end

      private

      # The contract always supplies (record_type, record_id[, name]); anything
      # else has no single-table access path and must not silently scan.
      def query_records
        unless @filters.key?(:record_type) && @filters.key?(:record_id)
          raise ActiveStorage::QueryNotSupported,
            "Unsupported attachment query #{@filters.keys.inspect}; supported: (record_type, record_id[, name])."
        end

        owner_query
      end

      def owner_query
        schema = ActiveStorage::AwsRecord.schema
        partition = @model.owner_partition(@filters[:record_type], @filters[:record_id])
        prefix = @model.attachment_prefix(@filters[:name])

        opts = {
          key_condition_expression: '#h = :h AND begins_with(#r, :r)',
          expression_attribute_values: { ':h' => partition, ':r' => prefix },
        }
        if schema.range_mode?
          opts[:expression_attribute_names] = { '#h' => schema.partition_attr, '#r' => schema.sort_attr }
          opts[:consistent_read] = true
        else
          opts[:index_name] = schema.index_name
          opts[:expression_attribute_names] = { '#h' => schema.index_partition_attr, '#r' => schema.index_sort_attr }
        end
        @model.query(opts).to_a
      end

      # Apply residual equality filters and exclusions in Ruby.
      def filtered(records)
        records.select do |record|
          @filters.all? { |attr, value| matches?(record.public_send(attr), value) } &&
            @exclusions.none? { |excl| excl.any? { |attr, value| matches?(record.public_send(attr), value) } }
        end
      end

      def matches?(actual, expected)
        if expected.is_a?(Array)
          expected.map(&:to_s).include?(actual.to_s)
        else
          actual.to_s == expected.to_s
        end
      end

      # Materialized, ordered result that still supports the collection helpers.
      class Ordered
        include Enumerable

        def initialize(records, attributes)
          @records = records.sort_by { |record| attributes.map { |attr| sort_value(record.public_send(attr)) } }
          @attributes = attributes
        end

        def each(&block) = @records.each(&block)
        def to_a = @records.dup
        def pluck(*attrs)
          @records.map { |r| attrs.size == 1 ? r.public_send(attrs.first) : attrs.map { |a| r.public_send(a) } }
        end

        private

        def sort_value(value)
          value.nil? ? '' : value.to_s
        end
      end

      class WhereChain
        def initialize(relation)
          @relation = relation
        end

        def not(attributes)
          @relation.not(attributes)
        end
      end
    end
  end
end
