require 'active_storage/aws_record/attachable'

module ActiveStorage
  module AwsRecord
    # Make a **greenfield** aws-record model an Active Storage attachment owner:
    # {Attachable}'s contract glue *plus* an aws-record persistence implementation
    # that runs Active Storage's callback chains. Use this when the model has no
    # persistence of its own; if it already defines +save+/+destroy+ (versioning,
    # events, search), include {Attachable} instead so this does not clobber them.
    #
    #   class Message
    #     include Aws::Record
    #     include ActiveStorage::AwsRecord::Owner
    #     string_attr :id, hash_key: true
    #     has_one_attached :avatar
    #     has_many_attached :images
    #   end
    #
    # Include +Aws::Record+ *before* +Owner+ (as above) so +Owner+'s +save+/+destroy+
    # sit above aws-record in the ancestor chain and their +super+ reaches it.
    module Owner
      extend ActiveSupport::Concern

      included do
        include ActiveStorage::AwsRecord::Persistence
        include ActiveStorage::AwsRecord::Attachable

        # Owner controls persistence, so it runs a real :commit chain (deferred
        # purges flush on commit) and a :rollback chain so they can be cancelled.
        # ({Attachable} defines the :save/:destroy/:validation chains.)
        define_model_callbacks :commit   unless respond_to?(:_commit_callbacks, true)
        define_model_callbacks :rollback unless respond_to?(:_rollback_callbacks, true)
      end

      # Persist via aws-record inside the :save (then :commit) chains. +super+ is
      # aws-record's terminal +save+ (not its +save!+), so this never re-enters.
      def save(opts = {})
        saved = false
        run_callbacks(:save) do
          stamp_physical_keys! if respond_to?(:stamp_physical_keys!)
          saved = super(opts)
          # A failed (invalid) save must not run after_save / flush attachments.
          throw :abort unless saved
          saved
        end
        run_callbacks(:commit) if saved
        saved
      end

      # Bang variant. Delegates to #save (one callback run) rather than calling
      # aws-record's #save! — which delegates back to #save and would run the
      # :save/:commit chains twice. A falsy #save is either a validation failure
      # (surface the messages) or a before_save +throw :abort+.
      def save!(opts = {})
        return self if save(opts)

        message = errors.any? ? errors.full_messages.to_sentence : 'Save halted by a before_save callback'
        raise ActiveStorage::RecordNotSaved.new(message, self)
      rescue Aws::Record::Errors::ConditionalWriteFailed => e
        raise ActiveStorage::RecordNotSaved.new(e.message, self)
      end

      # Remove the backend record *inside* the destroy callbacks so Active
      # Storage's +after_destroy+ cleanup sees +persisted? == false+, and only run
      # :commit when the destroy actually happened. The +delete!+ is guarded on
      # +persisted?+ so destroying a never-saved owner whose id collides with a
      # stored row cannot delete the stored row.
      def destroy(opts = {})
        destroyed = false
        run_callbacks(:destroy) do
          if persisted?
            delete!(opts)
            destroyed = true
          end
        end
        run_callbacks(:commit) if destroyed
        destroyed
      end
      alias_method :destroy!, :destroy
    end
  end
end
