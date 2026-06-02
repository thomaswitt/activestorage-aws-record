module ActiveStorage
  module AwsRecord
    # Raised, before any write, when a batched attachment change would exceed
    # DynamoDB's hard 100-action limit for +transact_write_items+. The operation
    # fails closed rather than chunking or falling back to per-row deletes — both
    # of which would reintroduce the partial-clear bug this batching exists to
    # prevent. Split the change into smaller batches instead.
    class TransactionTooLarge < StandardError; end

    # A fiber-local accumulator that batches the attachment *destroys* opened
    # inside an +Attachment.transaction+ block into a single DynamoDB
    # +transact_write_items+, so a multi-attachment clear / replace / detach is
    # atomic: DynamoDB deletes every row (and adjusts every blob refcount) or
    # none, instead of deleting some rows before a later one fails (the
    # partial-clear bug the generic +has_many+ paths would otherwise hit).
    #
    # *Creates are intentionally not buffered.* Active Storage's own create paths
    # (+CreateOne+/+CreateMany+) clean up newly-built blob/attachment records when
    # a +save!+ raises synchronously; deferring those writes to commit would move
    # the failure past that cleanup. Only destroys — whose sole failure mode is
    # *partial* multi-row deletion — are batched here.
    #
    # Fiber-safe (Falcon): the active context lives in +Fiber[]+, never a class or
    # thread global, so independent request fibers (Falcon assigns one per request)
    # each get their own transaction. The grouped-destroy blocks are executed
    # synchronously on one fiber; +Fiber[]+ is inherited by a *child* fiber, so do
    # not spawn an Async task / +Fiber.new+ inside an +Attachment.transaction+ block
    # (it would join the parent's buffer rather than open its own).
    class Transaction
      # DynamoDB's hard ceiling on actions in one +transact_write_items+ call.
      MAX_TRANSACT_ITEMS = 100

      FIBER_KEY = :active_storage_aws_record_transaction

      class << self
        # @return [Transaction, nil] the transaction active on this fiber.
        def current
          Fiber[FIBER_KEY]
        end

        # Run +block+ inside a transaction. A *nested* call joins the enclosing
        # transaction — its buffered destroys flush only at the outermost commit.
        # The outermost call commits the buffer on success; on any exception it
        # discards the buffer *unwritten*, so the block is atomic (nothing is
        # deleted). The fiber-local context is always cleared on the way out.
        #
        # @param model [Class] the Attachment class that opened the transaction.
        def run(model)
          return yield if current # nested: join the outer transaction

          tx = new(model)
          Fiber[FIBER_KEY] = tx
          begin
            result = yield
            tx.commit!
            result
          ensure
            Fiber[FIBER_KEY] = nil
          end
        end
      end

      def initialize(model)
        @model = model
        @destroys = []
      end

      # Buffer one attachment destroy/delete for the commit.
      def enqueue_destroy(attachment)
        @destroys << attachment
      end

      # Flush the buffered destroys:
      # * 0 → nothing;
      # * 1 → the existing per-row path (+#commit_destroy!+), which keeps its
      #   idempotent duplicate-purge / orphaned-blob recovery;
      # * ≥2 → one coalesced +transact_write_items+ (one delete per attachment row,
      #   one refcount +ADD+ per *distinct* blob, since DynamoDB forbids two
      #   actions on the same item in a transaction).
      def commit!
        return if @destroys.empty?

        if @destroys.size == 1
          @destroys.first.commit_destroy!
          return
        end

        items = transact_items
        if items.size > MAX_TRANSACT_ITEMS
          deletes = items.count { |item| item.key?(:delete) }
          raise TransactionTooLarge,
            "Atomic attachment change needs #{items.size} DynamoDB actions, over the " \
            "#{MAX_TRANSACT_ITEMS}-action transaction limit (#{deletes} attachments, " \
            "#{items.size - deletes} blobs). Split the change into smaller batches."
        end

        @model.dynamodb_client.transact_write_items(transact_items: items)
        @destroys.each(&:mark_destroyed!)
      rescue Aws::DynamoDB::Errors::TransactionCanceledException => e
        # A conditional failure cancels the *whole* batch (a row or blob vanished
        # under a concurrent change), so nothing was written. Surface it as a
        # destroy failure; the generic path resets its deferred purges and
        # re-raises. Refusing a partial result here is the point of batching.
        raise ActiveStorage::RecordNotDestroyed.new(
          "Failed to destroy #{@destroys.size} attachments atomically: #{e.message}", @destroys.first
        )
      rescue Aws::DynamoDB::Errors::ServiceError => e
        # Any other DynamoDB failure (throttling, network) also wrote nothing;
        # map it to RecordNotDestroyed too, matching the per-row #destroy contract.
        raise ActiveStorage::RecordNotDestroyed.new("Failed to destroy attachment: #{e.message}", @destroys.first)
      end

      private

      # One delete per attachment row, plus one coalesced refcount update per
      # distinct blob (delta = −the number of its buffered destroys), so the same
      # blob attached twice yields a single +ADD #c -2+ rather than two rejected
      # operations on one item. Rows are de-duplicated by physical key first: the
      # generic paths only ever enqueue distinct rows, but the public reentrant
      # +Attachment.transaction+ could buffer the *same* row twice (e.g. a nested
      # purge), which DynamoDB would reject as two actions on one item — collapsing
      # it to a single delete keeps that an idempotent no-op, as the per-row path is.
      def transact_items
        rows    = @destroys.uniq(&:physical_key)
        deletes = rows.map { |attachment| { delete: attachment.delete_transact_item } }
        deltas  = rows.each_with_object(Hash.new(0)) { |attachment, h| h[attachment.blob_id] -= 1 }
        updates = deltas.map { |blob_id, delta| { update: @model.blob_count_update(blob_id, delta) } }
        deletes + updates
      end
    end
  end
end
