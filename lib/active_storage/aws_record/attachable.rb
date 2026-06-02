module ActiveStorage
  module AwsRecord
    # Mix into an aws-record model that **already manages its own persistence**
    # (its own +save+/+destroy+ — versioning, events, search) to make it an Active
    # Storage attachment owner *without* the gem taking over persistence. It
    # contributes only the owner-*contract* glue Active Storage's generic builder
    # needs: the callback chains it hooks, a +changed?+ bridge, owner resolution,
    # and the +has_one_attached+/+has_many_attached+ macros.
    #
    #   class Document < BaseModel        # BaseModel already defines save/destroy
    #     include ActiveStorage::AwsRecord::Attachable
    #     has_many_attached :files
    #
    #     def save(*)    = run_attachment_save    { super }
    #     def destroy(*) = run_attachment_destroy { delete! if persisted? }
    #   end
    #
    # The host keeps its own +save+/+destroy+, but those **must run** Active
    # Storage's +:save+ (and, if defined, +:commit+) and +:destroy+ callback
    # chains — that is how attachments flush/upload and are cleaned up. If the host
    # already runs ActiveModel +:save+/+:destroy+ callbacks it works as-is;
    # otherwise wrap raw persistence with {#run_attachment_save} /
    # {#run_attachment_destroy}.
    #
    # For a greenfield model with **no** persistence of its own, use {Owner}, which
    # is {Attachable} plus an aws-record save/destroy implementation.
    #
    # Assumes the host already +include Aws::Record+ (for +find_with_opts+/+dirty?+/
    # +hash_key+). Owners must be single-hash-key (the contract stores one id).
    module Attachable
      extend ActiveSupport::Concern

      included do
        # The generic builder requires :validation + :save + :destroy callback
        # chains and installs a :validation hook for analysis. Including these is
        # idempotent.
        include ActiveModel::Validations
        include ActiveModel::Validations::Callbacks
        extend ActiveModel::Callbacks

        # Define ONLY the chains the host does not already run, so a model with its
        # own :save/:destroy callbacks keeps them and Active Storage just hooks the
        # existing chain. :commit is deliberately NOT auto-defined: Active Storage
        # switches uploads to +after_commit+ the instant +_commit_callbacks+ exists
        # (see the generic builder), so defining it without running it would write
        # the attachment row but never upload the file. {Owner} (which controls
        # persistence) defines and runs :commit itself.
        define_model_callbacks :save    unless respond_to?(:_save_callbacks, true)
        define_model_callbacks :destroy unless respond_to?(:_destroy_callbacks, true)

        # Active Storage uses +changed?+ to decide whether +attach+ saves the owner
        # immediately; aws-record exposes the same state as +dirty?+. Bridge it
        # only when the host has no +changed?+ of its own (never clobber one).
        unless method_defined?(:changed?) || private_method_defined?(:changed?)
          define_method(:changed?) { dirty? }
        end

        include ActiveStorage::Attached::Model
      end

      class_methods do
        # Attachment rows store the owner under this name; override for STI-like
        # schemes.
        def polymorphic_name
          name
        end

        # Active Storage resolves an owner from the bare +record_id+ it stored
        # (+record_type.constantize.active_storage_find(record_id)+). aws-record's
        # +#find+ is key-hash-based, so adapt it on the single hash key here rather
        # than shadowing the host's own +#find+ (which app code may call with
        # aws-record semantics).
        def active_storage_find(id)
          find_with_opts(key: { hash_key => id }) ||
            raise(ActiveStorage::RecordNotFound, "Couldn't find #{name} with id=#{id.inspect}")
        rescue Aws::Record::Errors::KeyMissing
          raise ActiveStorage::RecordNotFound, "Couldn't find #{name} with id=#{id.inspect}"
        end
      end

      # Run your model's real save inside Active Storage's +:save+ chain so its
      # attachments flush and upload (with no +:commit+ chain the upload happens in
      # +after_save+). Aborts the chain — so nothing flushes — if the save returns
      # falsy. Returns the save result.
      def run_attachment_save
        result = nil
        run_callbacks(:save) do
          result = yield
          throw :abort unless result
          result
        end
        result
      end

      # Run your model's real deletion inside the +:destroy+ chain so attachments
      # are cleaned up. The block must make the owner non-persisted (e.g. +delete!+)
      # or Active Storage's +after_destroy+ cleanup is skipped (it only runs for an
      # owner that was persisted and no longer is).
      def run_attachment_destroy(&block)
        run_callbacks(:destroy, &block)
      end
    end
  end
end
