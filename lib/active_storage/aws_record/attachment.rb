require 'active_storage/aws_record/item'
require 'active_storage/aws_record/relation'
require 'active_storage/aws_record/transaction'

module ActiveStorage
  module AwsRecord
    # The join item between an owner record and a blob. Stored under the owner's
    # partition (+ns#Owner#<record_type>#<record_id>+) with a sort key of
    # +ns#Attachment#<name>#<id>+, so loading an owner's attachments (the
    # contract's hot path) is a single base-table query. Creating/destroying an
    # attachment also adjusts a strongly-consistent reference count on its blob,
    # so a shared blob is only purged once no attachment references it.
    class Attachment
      include ActiveStorage::AwsRecord::Item

      string_attr :id,           database_attribute_name: 'as_id'
      string_attr :record_type,  database_attribute_name: 'as_record_type'
      string_attr :record_id,    database_attribute_name: 'as_record_id'
      string_attr :name,         database_attribute_name: 'as_name'
      string_attr :blob_id,      database_attribute_name: 'as_blob_id'
      string_attr :created_at,   database_attribute_name: 'as_created_at'
      string_attr :entity,       database_attribute_name: 'as_entity', default_value: 'Attachment'

      # Transient flags Active Storage's change objects set on attachments; not
      # persisted to DynamoDB.
      attr_accessor :pending_upload, :immediate_variants_processed

      class << self
        # Open a real, fiber-local DynamoDB transaction (see {Transaction}). The
        # generic +has_many+ clear/replace/detach paths wrap their per-row
        # destroys in this; buffering them into one +transact_write_items+ makes a
        # multi-attachment change atomic, instead of deleting some rows before a
        # later one fails. Nested calls join the enclosing transaction. *Only
        # destroys are buffered* — creates stay synchronous so Active Storage's own
        # failed-save cleanup still fires.
        def transaction(&block)
          ActiveStorage::AwsRecord::Transaction.run(self, &block)
        end

        # Atomic +ADD+ on a blob's reference count by +blob_id+, guarded on the
        # blob item still existing (so a stale/purged blob is never resurrected by
        # the ADD). Shared by the per-row path and the batched commit (which
        # coalesces one update per distinct blob).
        def blob_count_update(blob_id, delta)
          blob_keys = ActiveStorage::AwsRecord::Blob.logical_keys_for(blob_id)
          {
            table_name: ActiveStorage::AwsRecord::Blob.table_name,
            key: ActiveStorage::AwsRecord::Blob.physical_key(**blob_keys),
            update_expression: 'ADD #c :delta',
            condition_expression: 'attribute_exists(#h)',
            expression_attribute_names: { '#c' => 'as_attachments_count', '#h' => schema.partition_attr },
            expression_attribute_values: { ':delta' => delta },
          }
        end

        def find_by(attributes)
          ActiveStorage::AwsRecord::Relation.new(self).find_by(attributes)
        end

        def where(attributes = nil)
          ActiveStorage::AwsRecord::Relation.new(self).where(attributes)
        end

        # The owner-adjacency partition key for a (record_type, record_id) pair.
        def owner_partition(record_type, record_id)
          ns_key('Owner', record_type, record_id)
        end

        # The sort-key prefix for an owner's attachments, optionally narrowed to a
        # single attachment +name+, with a trailing separator so +begins_with+
        # cannot bleed across names.
        def attachment_prefix(name = nil)
          base = name ? ns_key('Attachment', name) : ns_key('Attachment')
          "#{base}#{ActiveStorage::AwsRecord.config.separator}"
        end

        # Empty relation used by +Blob#attachments+ (see Blob): returns nothing
        # for a non-persisted blob, and refuses to materialize on a persisted one
        # (no blob→attachment index exists by design).
        def none_for_blob(persisted)
          NullBlobRelation.new(persisted)
        end
      end

      def initialize(attributes = {})
        super()
        attributes = attributes.dup
        record = attributes.delete(:record) || attributes.delete('record')
        blob = attributes.delete(:blob) || attributes.delete('blob')
        self.id ||= generate_uuid
        assign_attributes(attributes) if attributes.any?
        self.record = record if record
        self.blob = blob if blob
      end

      def assign_attributes(attributes)
        attributes = attributes.dup
        record = attributes.delete(:record) || attributes.delete('record')
        blob = attributes.delete(:blob) || attributes.delete('blob')
        attributes.each { |name, value| public_send("#{name}=", value) }
        self.record = record if record
        self.blob = blob if blob
      end

      def logical_keys
        {
          h: self.class.owner_partition(record_type, record_id),
          r: ns_key('Attachment', name, id),
          item_id: ns_key('Attachment', id),
        }
      end

      def record=(record)
        @record = record
        self.record_type = ActiveStorage::Attached::Changes.polymorphic_name(record)
        self.record_id = record.id.to_s
      end

      # Resolve the owner from the stored (record_type, record_id). Prefer the
      # +active_storage_find+ hook ({Attachable}/{Owner} owners define it so an
      # aws-record model with a key-hash +#find+ resolves correctly), and fall
      # back to the generic contract's bare-id +find(record_id)+ (the gem's own
      # +Blob+/+VariantRecord+ owners override that).
      def record
        @record ||= begin
          owner_class = record_type.constantize
          if owner_class.respond_to?(:active_storage_find)
            owner_class.active_storage_find(record_id)
          else
            owner_class.find(record_id)
          end
        end
      end

      def blob=(blob)
        @blob = blob
        self.blob_id = blob&.id
      end

      def blob
        @blob ||= ActiveStorage::AwsRecord::Blob.find(blob_id)
      end

      def signed_id
        blob.signed_id
      end

      # Persist the join item. On create, atomically (DynamoDB transaction) put
      # the attachment and increment its blob's reference count — guarding the
      # increment on the blob still existing so a purged blob is never resurrected.
      def save!(opts = {})
        self.created_at ||= ActiveStorage::AwsRecord::Blob.current_timestamp
        if new_record?
          stamp_physical_keys!
          transactional_create!
        end
        # A persisted attachment join row is immutable (record/blob/name are
        # fixed at creation), so a re-save is a deliberate no-op. Calling super
        # here would invoke aws-record's #save!, which delegates to #save — and
        # because we override #save to call #save!, that recurses infinitely
        # (SystemStackError). Active Storage re-saves already-persisted
        # attachments during its attach flow, so this path is hot.
        self
      rescue Aws::DynamoDB::Errors::TransactionCanceledException, Aws::DynamoDB::Errors::ConditionalCheckFailedException,
             Aws::Record::Errors::ConditionalWriteFailed, Aws::Record::Errors::ValidationError => e
        raise ActiveStorage::RecordNotSaved.new(e.message, self)
      end

      def save(opts = {})
        save!(opts)
        true
      rescue ActiveStorage::RecordNotSaved
        false
      end

      # Delete the join item and decrement its blob's reference count atomically.
      # Must complete or raise (never return false) for the generic
      # dependent-destroy path; a failure maps to +RecordNotDestroyed+.
      def destroy
        @previously_persisted = persisted?
        enqueue_or_destroy if @previously_persisted
        true
      rescue Aws::DynamoDB::Errors::ServiceError => e
        # ServiceError, not Errors::Error: every DynamoDB error (throttling,
        # conditional failure, a re-raised cancellation) subclasses ServiceError,
        # while Errors::Error has no subclasses — rescuing it would catch nothing.
        raise ActiveStorage::RecordNotDestroyed.new("Failed to destroy attachment: #{e.message}", self)
      end

      # Like #destroy (it also decrements the blob count, so the count never
      # drifts), but used by replace/detach paths that manage the blob
      # themselves; skips +touch+/blob cleanup.
      def delete
        @previously_persisted = persisted?
        enqueue_or_destroy if @previously_persisted
        true
      end

      def previously_persisted?
        @previously_persisted
      end

      # --- Internal API used by {Transaction} when batching destroys ----------

      # Flush a single buffered destroy: identical to a non-transactional destroy,
      # so its idempotent duplicate-purge / orphaned-blob recovery is preserved
      # (the batched ≥2 path cannot offer per-row recovery).
      def commit_destroy!
        transactional_destroy!
      end

      # The +Delete+ action (without the +{ delete: }+ wrapper) for this
      # attachment's row, guarded so a row that already vanished cancels the
      # transaction rather than silently masking a concurrent change.
      def delete_transact_item
        {
          table_name: self.class.table_name,
          key: physical_key,
          condition_expression: 'attribute_exists(#h)',
          expression_attribute_names: { '#h' => schema.partition_attr },
        }
      end

      # Purge the attachment and (if unreferenced) its blob. Assumes no *ambient*
      # +Attachment.transaction+ is open: the +destroy+ here commits at the end of
      # its own block, so the refcount is decremented before +blob.purge+ checks
      # it. Nested inside an outer transaction the decrement would not have
      # committed yet, so the blob's foreign-key guard would (harmlessly) refuse
      # the purge — the contract never calls purge from inside a transaction.
      def purge
        self.class.transaction do
          destroy
          touch_record
        end
        blob&.purge
      end

      # See {#purge}: assumes no ambient +Attachment.transaction+.
      def purge_later
        self.class.transaction do
          destroy
          touch_record
        end
        blob&.purge_later
      end

      # Upload the io to the service and (optionally) analyze, mirroring the
      # reference backend's attachment upload lifecycle.
      def uploaded(io:)
        blob.local_io = io
        blob.analyze_without_saving unless blob.analyzed? || skip_later_analysis?
        io.rewind if io.respond_to?(:rewind)
        blob.upload_without_unfurling(io)
        blob.save! if blob.persisted?
        blob.mirror_later
        blob.analyze_later unless blob.analyzed? || skip_later_analysis?
      ensure
        blob.local_io = nil
      end

      def variant(transformations)
        blob.variant(transformations_by_name(transformations))
      end

      def preview(transformations)
        blob.preview(transformations_by_name(transformations))
      end

      def representation(transformations)
        blob.representation(transformations_by_name(transformations))
      end

      def as_json(options = nil)
        { id: id, name: name, record_type: record_type, record_id: record_id, blob_id: blob_id }.as_json(options)
      end

      delegate_missing_to :blob

      private

      # Buffer this destroy into the ambient +Attachment.transaction+ (so a
      # multi-row clear/replace/detach commits atomically), or, outside one,
      # delete immediately through the per-row path.
      def enqueue_or_destroy
        if (tx = ActiveStorage::AwsRecord::Transaction.current)
          tx.enqueue_destroy(self)
        else
          transactional_destroy!
        end
      end

      def transactional_create!
        dynamodb_client.transact_write_items(
          transact_items: [
            { put: {
              table_name: self.class.table_name,
              item: save_values,
              condition_expression: 'attribute_not_exists(#h)',
              expression_attribute_names: { '#h' => schema.partition_attr },
            } },
            { update: blob_count_update(1) },
          ]
        )
        mark_persisted!
      end

      def transactional_destroy!
        dynamodb_client.transact_write_items(
          transact_items: [
            { delete: delete_transact_item },
            { update: blob_count_update(-1) },
          ]
        )
        mark_destroyed!
      rescue Aws::DynamoDB::Errors::TransactionCanceledException => e
        handle_destroy_cancellation(e)
      end

      # In a transaction any failed condition cancels everything, so decide what
      # to redo from the per-item cancellation reasons:
      # * attachment row already gone (duplicate purge) → idempotent no-op;
      # * blob already purged → the +ADD -1+ would have created a zombie blob, so
      #   the transaction is rejected by its +attribute_exists+ guard; just delete
      #   the orphaned attachment row on its own.
      def handle_destroy_cancellation(error)
        reasons = error.cancellation_reasons || []
        attachment_failed = reasons[0]&.code == 'ConditionalCheckFailed'
        blob_failed = reasons[1]&.code == 'ConditionalCheckFailed'

        if attachment_failed
          mark_destroyed!
        elsif blob_failed
          delete!
          mark_destroyed!
        else
          raise
        end
      end

      # This attachment's blob refcount +ADD+ (delegates to the class helper so the
      # batched commit path can coalesce one update per distinct blob).
      def blob_count_update(delta)
        self.class.blob_count_update(blob_id, delta)
      end

      def touch_record
        record.touch if record.respond_to?(:touch) && record.respond_to?(:persisted?) && record.persisted?
      rescue ActiveStorage::RecordNotFound
        nil
      end

      def reflection
        record_type.constantize.attachment_reflections[name]
      end

      def named_variants
        reflection&.named_variants || {}
      end

      def transformations_by_name(transformations)
        case transformations
        when Symbol
          variant_name = transformations
          named_variants.fetch(variant_name) do
            raise ArgumentError, "Cannot find variant :#{variant_name} for #{record_type}##{name}"
          end.transformations
        else
          transformations
        end
      end

      def analyze_option
        reflection&.options&.fetch(:analyze, nil)
      end

      def skip_later_analysis?
        (analyze_option || ActiveStorage.analyze) == :lazily
      end

      # Empty relation backing +Blob#attachments+.
      class NullBlobRelation
        include Enumerable

        def initialize(persisted)
          @persisted = persisted
        end

        def each(&block)
          guard!
          [].each(&block)
        end

        def find(*)
          guard!
          nil
        end

        def to_a
          guard!
          []
        end
        alias_method :to_ary, :to_a

        def any?
          guard!
          false
        end

        def empty?
          guard!
          true
        end

        private

        def guard!
          return false unless @persisted

          raise ActiveStorage::QueryNotSupported,
            'Blob#attachments is unsupported on a persisted blob in the single-table backend ' \
            '(there is no blob→attachment index by design).'
        end
      end
    end
  end
end
