require 'base64'
require 'active_storage/aws_record/item'
require 'active_storage/aws_record/owner'

module ActiveStorage
  module AwsRecord
    # Tracks a processed variant of a blob when
    # +config.active_storage.track_variants+ is on. It is co-located in its
    # blob's partition (+ns#Blob#<blob_id>+) with a sort key of
    # +ns#VariantRecord#<variation_digest>+, so the (blob_id, variation_digest)
    # pair is unique by construction and the blob and all its variants form one
    # item collection. It is itself an attachment owner (+has_one_attached
    # :image+); its owner +id+ is a reversible, +#+-free encoding of the natural
    # key so +find(id)+ resolves it.
    class VariantRecord
      include ActiveStorage::AwsRecord::Item
      include ActiveStorage::AwsRecord::Owner

      ID_DELIMITER = ' '

      # Raised internally when the variant row already exists (the conditional
      # +Put+ lost the race), so create_or_find_by! can fall back to +find+ —
      # while genuine post-write failures (e.g. the image attachment) propagate.
      class CreateConflict < StandardError; end

      string_attr :blob_id,          database_attribute_name: 'as_blob_id'
      string_attr :variation_digest, database_attribute_name: 'as_variation_digest'
      string_attr :entity,           database_attribute_name: 'as_entity', default_value: 'VariantRecord'

      class << self
        # Contract +find(id)+: decode the reversible id back to the natural key.
        def find(id)
          blob_id, variation_digest = decode_id(id)
          find_by(blob_id: blob_id, variation_digest: variation_digest) ||
            raise(ActiveStorage::RecordNotFound, "Couldn't find #{name} with id=#{id.inspect}")
        rescue ArgumentError
          raise ActiveStorage::RecordNotFound, "Couldn't find #{name} with id=#{id.inspect}"
        end

        def find_by(blob_id:, variation_digest:)
          keys = logical_keys_for(blob_id.to_s, variation_digest)
          get_item(**keys)
        end

        # Owner resolution for Active Storage (VariantRecord is an attachment owner
        # via +image+). Delegate to the reversible-id +#find+: {Attachable}'s default
        # +find_with_opts(hash_key => id)+ adapter cannot address the composite key.
        def active_storage_find(id)
          find(id)
        end

        # Race-safe creation: a conditional put on the variant's own key, paired
        # with a check that the source blob still exists, so a variant can never
        # be created against a just-purged blob. A condition failure (the variant
        # already exists, or the blob is gone) falls back to find. The block (used
        # by VariantWithRecord to +image.attach+ the processed file) runs before
        # save so the queued image attachment is flushed by the save callbacks.
        def create_or_find_by!(blob_id:, variation_digest:)
          record = new(blob_id: blob_id.to_s, variation_digest: variation_digest)
          yield record if block_given?
          record.save!
          record
        rescue CreateConflict
          # Only a genuine create conflict (the row already exists) falls back to
          # find — a post-write failure (image attachment, blob gone) propagates.
          # NOTE: the marker row commits just before its image attachment is
          # flushed, so a *concurrent* processor that loses the race here can
          # briefly observe the record before its image is attached (a transient
          # that resolves once the winner finishes; like Active Storage's
          # create-then-upload, but without AR's single enclosing transaction).
          find_by(blob_id: blob_id, variation_digest: variation_digest) ||
            raise(ActiveStorage::RecordNotSaved.new('Failed to create or find variant record', record))
        end

        # All variant records for a blob (used by Blob#destroy's variant sweep).
        # Mode A: strong base-table query under the blob partition. Mode B: GSI.
        def where_blob(blob_id)
          schema = ActiveStorage::AwsRecord.schema
          partition = ns_key('Blob', blob_id)
          prefix = "#{ns_key('VariantRecord')}#{ActiveStorage::AwsRecord.config.separator}"
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
          query(opts).to_a
        end

        # Logical keys for a (blob_id, variation_digest) pair without an instance.
        def logical_keys_for(blob_id, variation_digest)
          {
            h: ns_key('Blob', blob_id),
            r: ns_key('VariantRecord', variation_digest),
            item_id: ns_key('Blob', blob_id, 'VariantRecord', variation_digest),
          }
        end

        def encode_id(blob_id, variation_digest)
          Base64.urlsafe_encode64("#{blob_id}#{ID_DELIMITER}#{variation_digest}", padding: false)
        end

        def decode_id(id)
          Base64.urlsafe_decode64(id).split(ID_DELIMITER, 2)
        end
      end

      def logical_keys
        self.class.logical_keys_for(blob_id, variation_digest)
      end

      # Persist the variant row transactionally *and* run the owner save/commit
      # callbacks, so a queued +image+ attachment (from create_or_find_by!'s
      # block) is saved and uploaded. Overrides Owner#save! to substitute the
      # transactional create for aws-record's plain put. If a step *after* the row
      # write fails (e.g. the image attachment), the half-written row is removed
      # so it does not become a markerless "poison" record.
      def save!(opts = {})
        marker_written = false
        completed = run_callbacks(:save) do
          stamp_physical_keys!
          if new_record?
            transactional_create!
            marker_written = true
          end
          true
        end
        raise ActiveStorage::RecordNotSaved.new('Save halted by a before_save callback', self) unless completed

        run_callbacks(:commit)
        self
      rescue CreateConflict
        raise
      rescue StandardError
        destroy_marker! if marker_written
        raise
      end

      def save(opts = {})
        save!(opts)
        true
      rescue ActiveStorage::RecordNotSaved, CreateConflict
        false
      end

      # The owner id used as +record_id+ for the +image+ attachment; reversible
      # so VariantRecord.find(id) resolves the natural key.
      def id
        return nil if blob_id.nil? || variation_digest.nil?

        self.class.encode_id(blob_id, variation_digest)
      end

      private

      def transactional_create!
        blob_keys = ActiveStorage::AwsRecord::Blob.logical_keys_for(blob_id)
        dynamodb_client.transact_write_items(
          transact_items: [
            { put: {
              table_name: self.class.table_name,
              item: save_values,
              condition_expression: 'attribute_not_exists(#h)',
              expression_attribute_names: { '#h' => schema.partition_attr },
            } },
            { condition_check: {
              table_name: ActiveStorage::AwsRecord::Blob.table_name,
              key: ActiveStorage::AwsRecord::Blob.physical_key(**blob_keys),
              condition_expression: 'attribute_exists(#h)',
              expression_attribute_names: { '#h' => schema.partition_attr },
            } },
          ]
        )
        mark_persisted!
      rescue Aws::DynamoDB::Errors::TransactionCanceledException => e
        # reasons[0] = the variant Put, reasons[1] = the blob existence check.
        reasons = e.cancellation_reasons || []
        put_failed  = reasons[0]&.code == 'ConditionalCheckFailed'
        blob_failed = reasons[1]&.code == 'ConditionalCheckFailed'
        # Only a pure put-conflict (variant exists, source blob still present) is
        # a CreateConflict; if the blob is gone, surface a genuine failure.
        raise CreateConflict if put_failed && !blob_failed

        raise ActiveStorage::RecordNotSaved.new(e.message, self)
      rescue Aws::DynamoDB::Errors::ConditionalCheckFailedException, Aws::Record::Errors::ConditionalWriteFailed,
             Aws::Record::Errors::ValidationError => e
        raise ActiveStorage::RecordNotSaved.new(e.message, self)
      end

      # Remove a half-written variant row (best effort) so a post-write failure
      # does not leave a markerless record that blocks regeneration. Also purge
      # the image attachment/blob if it was already created during +after_save+,
      # so it is not orphaned.
      def destroy_marker!
        image.purge if image.attached?
        dynamodb_client.delete_item(table_name: self.class.table_name, key: physical_key)
        mark_destroyed!
      rescue StandardError
        nil
      end
    end
  end
end
