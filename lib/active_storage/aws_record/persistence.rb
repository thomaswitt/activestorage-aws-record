require 'securerandom'

module ActiveStorage
  module AwsRecord
    # Generic aws-record plumbing shared by every model that participates in the
    # Active Storage owner contract — both the gem's own entities and the
    # application's owner models (which include {Owner}). It deliberately holds
    # *no* single-table key logic (that lives in {Item}, mixed only into the
    # gem's three entities), so an application owner keeps its own key schema.
    #
    # Provides: aws-record + GlobalID, the shared client, equality by class + id,
    # +changed?+ → aws-record +dirty?+, raw attribute access, and helpers to mark
    # an instance persisted/destroyed after a raw write.
    module Persistence
      extend ActiveSupport::Concern

      included do
        include Aws::Record
        include GlobalID::Identification

        # Defined here, after +include Aws::Record+, so it shadows aws-record's
        # +find(opts)+ class method with the contract's +find(id)+. Single
        # hash-key owners (the common case) use this as-is; the gem's own
        # composite-key entities override it.
        def self.find(id)
          record = find_with_opts(key: { hash_key => id })
          record || raise(ActiveStorage::RecordNotFound, "Couldn't find #{name} with id=#{id.inspect}")
        rescue Aws::Record::Errors::KeyMissing
          raise ActiveStorage::RecordNotFound, "Couldn't find #{name} with id=#{id.inspect}"
        end
      end

      class_methods do
        # @return [Aws::DynamoDB::Client] the shared client.
        def dynamodb_client
          ActiveStorage::AwsRecord.dynamodb_client
        end
      end

      def dynamodb_client
        self.class.dynamodb_client
      end

      def ==(other)
        other.instance_of?(self.class) && id.present? && id == other.id
      end
      alias_method :eql?, :==

      def hash
        [self.class, id].hash
      end

      # Active Storage's generic owner path checks +changed?+; aws-record names
      # the same concept +dirty?+.
      def changed?
        dirty?
      end

      # Raw attribute access via aws-record's data object (it has no AR-style
      # +self[:attr]+), for use inside overridden accessors.
      def read_attribute(name)
        instance_variable_get('@data').get_attribute(name)
      end

      def write_attribute(name, value)
        instance_variable_get('@data').set_attribute(name, value)
      end

      # Mark this instance persisted after a raw (non-aws-record) write.
      def mark_persisted!
        data = instance_variable_get('@data')
        data.new_record = false
        data.destroyed = false
        data.clean!
      end

      # Mark this instance destroyed after a raw delete.
      def mark_destroyed!
        instance_variable_get('@data').destroyed = true
      end

      private

      def generate_uuid
        SecureRandom.uuid
      end
    end
  end
end
