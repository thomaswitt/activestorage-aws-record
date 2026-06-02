require 'active_storage/aws_record/item'
require 'active_storage/aws_record/owner'

module ActiveStorage
  module AwsRecord
    # The blob metadata item. Mirrors the behavior of the default Active Record
    # blob (and the in-memory reference backend) but persists through aws-record.
    # Bytes still live in the configured Active Storage Service; only metadata is
    # here. It is also an attachment owner (for +preview_image+) and carries a
    # strongly-consistent +attachments_count+ used by #destroy to protect shared
    # blobs.
    #
    # Single-table layout: the blob and all of its variant records share one
    # partition (+ns#Blob#<id>+); the blob's own item is the collection root.
    class Blob
      include ActiveStorage::AwsRecord::Item
      include ActiveStorage::AwsRecord::Owner
      include ActiveStorage::Servable

      MINIMUM_TOKEN_LENGTH = 28

      # Every non-key attribute carries an explicit, namespaced DynamoDB name so
      # it can never collide with the table's (app-chosen) key attribute names.
      string_attr  :id,            database_attribute_name: 'as_id'
      string_attr  :key,           database_attribute_name: 'as_key'
      string_attr  :filename,      database_attribute_name: 'as_filename'
      string_attr  :content_type,  database_attribute_name: 'as_content_type'
      integer_attr :byte_size,     database_attribute_name: 'as_byte_size'
      string_attr  :checksum,      database_attribute_name: 'as_checksum'
      # Fiber/thread-safe default: a lambda yields a fresh hash per instance
      # instead of sharing one mutable hash across all records.
      map_attr     :metadata,      database_attribute_name: 'as_metadata', default_value: -> { {} }
      string_attr  :service_name,  database_attribute_name: 'as_service_name'
      string_attr  :created_at,    database_attribute_name: 'as_created_at'
      integer_attr :attachments_count, database_attribute_name: 'as_attachments_count', default_value: 0
      string_attr  :entity,        database_attribute_name: 'as_entity', default_value: 'Blob'

      attr_accessor :local_io

      class << self
        def services
          ActiveStorage::Services.registry
        end

        def services=(registry)
          ActiveStorage::Services.registry = registry
        end

        def service
          ActiveStorage::Services.default
        end

        def service=(service)
          ActiveStorage::Services.default = service
        end

        # Microsecond-precision, fixed-width UTC ISO8601 — lexically sortable (so
        # has_many ordering by created_at is correct) and parseable back to a Time.
        def current_timestamp
          Time.now.utc.iso8601(6)
        end

        def generate_unique_secure_token(length: MINIMUM_TOKEN_LENGTH)
          SecureRandom.base36(length)
        end

        # Contract +find(id)+: GetItem on the blob's collection-root key.
        def find(id)
          keys = logical_keys_for(id)
          get_item(**keys) ||
            raise(ActiveStorage::RecordNotFound, "Couldn't find #{name} with id=#{id.inspect}")
        rescue ArgumentError, Aws::Record::Errors::KeyMissing
          raise ActiveStorage::RecordNotFound, "Couldn't find #{name} with id=#{id.inspect}"
        end

        # Owner resolution for Active Storage (Blob is itself an attachment owner
        # via +preview_image+). Delegate to the composite-key +#find+: {Attachable}'s
        # default +find_with_opts(hash_key => id)+ adapter cannot address the
        # +ns#Blob#<id>+ key.
        def active_storage_find(id)
          find(id)
        end

        # Logical keys for a blob id without an instance (used by the attachment
        # refcount transaction). The blob and its variants share one partition.
        def logical_keys_for(blob_id)
          root = ns_key('Blob', blob_id)
          { h: root, r: root, item_id: root }
        end

        def build_after_unfurling(key: nil, io:, filename:, content_type: nil, metadata: nil, service_name: nil, identify: true, record: nil)
          new(key: key, filename: filename, content_type: content_type, metadata: metadata, service_name: service_name).tap do |blob|
            blob.unfurl(io, identify: identify)
          end
        end

        def create_after_unfurling!(key: nil, io:, filename:, content_type: nil, metadata: nil, service_name: nil, identify: true, record: nil)
          build_after_unfurling(key: key, io: io, filename: filename, content_type: content_type, metadata: metadata, service_name: service_name, identify: identify, record: record).tap(&:save!)
        end

        def create_and_upload!(key: nil, io:, filename:, content_type: nil, metadata: nil, service_name: nil, identify: true, record: nil)
          create_after_unfurling!(key: key, io: io, filename: filename, content_type: content_type, metadata: metadata, service_name: service_name, identify: identify, record: record).tap do |blob|
            blob.upload_without_unfurling(io)
          end
        end

        def create_before_direct_upload!(key: nil, filename:, byte_size:, checksum:, content_type: nil, metadata: nil, service_name: nil, record: nil)
          metadata = ActiveStorage.filter_blob_metadata(metadata || {})
          new(key: key, filename: filename, byte_size: byte_size, checksum: checksum, content_type: content_type, metadata: metadata, service_name: service_name).tap(&:save!)
        end

        def find_signed(id, record: nil, purpose: :blob_id)
          find_signed!(id, record: record, purpose: purpose)
        rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveStorage::RecordNotFound
          nil
        end

        def find_signed!(id, record: nil, purpose: :blob_id)
          find(ActiveStorage.verifier.verify(id, purpose: purpose.to_s))
        end

        def scope_for_strict_loading
          self
        end
      end

      def initialize(attributes = {})
        super
        self.id ||= generate_uuid
        self.key ||= self.class.generate_unique_secure_token
        self.metadata ||= {}
        self.service_name ||= self.class.service&.name&.to_s
        self.created_at ||= self.class.current_timestamp
        self.attachments_count ||= 0
      end

      # Logical keys: the blob and its variants share the +ns#Blob#<id>+ partition;
      # the blob's own sort key mirrors the partition (the collection root).
      def logical_keys
        self.class.logical_keys_for(id)
      end

      def signed_id(purpose: :blob_id, expires_in: nil, expires_at: nil)
        ActiveStorage.verifier.generate(id, purpose: purpose.to_s, expires_in: expires_in, expires_at: expires_at)
      end

      # Returns a Time (not the stored String), because Active Storage's proxy
      # controller passes +blob.created_at+ to +http_cache_forever+, which calls
      # +.utc+ on it for the Last-Modified header.
      def created_at
        raw = read_attribute(:created_at)
        return raw unless raw.is_a?(String)

        Time.iso8601(raw)
      rescue ArgumentError
        nil
      end

      def filename
        ActiveStorage::Filename.new(read_attribute(:filename).to_s)
      end

      def filename=(value)
        write_attribute(:filename, value&.to_s)
      end

      def custom_metadata
        indifferent_metadata[:custom] || {}
      end

      def identified = !!indifferent_metadata[:identified]
      def identified?(*) = identified
      def identified=(value)
        metadata_set(:identified, value)
      end

      def analyzed = !!indifferent_metadata[:analyzed]
      def analyzed?(*) = analyzed
      def analyzed=(value)
        metadata_set(:analyzed, value)
      end

      def composed = !!indifferent_metadata[:composed]
      def composed=(value)
        metadata_set(:composed, value)
      end

      def identify_without_saving
        return if identified?

        self.content_type ||= 'application/octet-stream'
        self.identified = true
      end

      def analyze_without_saving
        metadata_set(:analyzed, true)
      end

      def analyze
        analyze_without_saving
        save!
      end

      def analyze_later
        ActiveStorage::AnalyzeJob.perform_later(self)
      end

      def upload(io, identify: true)
        unfurl(io, identify: identify)
        upload_without_unfurling(io)
      end

      def unfurl(io, identify: true)
        self.checksum = service.compute_checksum(io)
        self.content_type = Marcel::MimeType.for(io, name: filename.to_s, declared_type: content_type) if content_type.nil? || identify
        self.byte_size = io.size
        self.identified = true
      end

      def upload_without_unfurling(io)
        service.upload(key, io, checksum: checksum, content_type: content_type)
      end

      def download(&block)
        service.download(key, &block)
      end

      def download_chunk(range)
        service.download_chunk(key, range)
      end

      def open(tmpdir: nil, &block)
        if local_io
          open_local_io(tmpdir: tmpdir, &block)
        else
          service.open(key, checksum: checksum, verify: !composed,
            name: ["ActiveStorage-#{id}-", filename.extension_with_delimiter], tmpdir: tmpdir, &block)
        end
      end

      def url(expires_in: ActiveStorage.service_urls_expire_in, disposition: :inline, filename: nil, **options)
        service.url(key, expires_in: expires_in, filename: ActiveStorage::Filename.wrap(filename || self.filename),
          content_type: content_type_for_serving, disposition: forced_disposition_for_serving || disposition, **options)
      end

      def service_url_for_direct_upload(expires_in: ActiveStorage.service_urls_expire_in)
        service.url_for_direct_upload(key, expires_in: expires_in, content_type: content_type,
          content_length: byte_size, checksum: checksum, custom_metadata: custom_metadata)
      end

      def service_headers_for_direct_upload
        service.headers_for_direct_upload(key, filename: filename, content_type: content_type,
          content_length: byte_size, checksum: checksum, custom_metadata: custom_metadata)
      end

      def content_type_for_serving = super
      def forced_disposition_for_serving = super

      def image? = content_type&.start_with?('image')
      def audio? = content_type&.start_with?('audio')
      def video? = content_type&.start_with?('video')
      def text? = content_type&.start_with?('text')

      def variable?
        ActiveStorage.variable_content_types.include?(content_type)
      end

      def previewable?
        ActiveStorage.previewers.any? { |klass| klass.accept?(self) }
      end

      def representable?
        variable? || previewable?
      end

      def variant(transformations)
        raise ActiveStorage::InvariableError unless variable?

        variant_class.new(self, ActiveStorage::Variation.wrap(transformations).default_to(default_variant_transformations))
      end

      def preview(transformations)
        raise ActiveStorage::UnpreviewableError unless previewable?

        ActiveStorage::Preview.new(self, transformations)
      end

      def representation(transformations)
        case
        when previewable? then preview(transformations)
        when variable?    then variant(transformations)
        else
          raise ActiveStorage::UnrepresentableError
        end
      end

      # The blob→attachment reverse lookup is intentionally unsupported (it is the
      # one access pattern that would force a secondary index; the generic path
      # only ever reaches it for a non-persisted blob, which has no rows). Returns
      # an empty, no-op relation; materializing it on a persisted blob raises.
      def attachments
        ActiveStorage::AwsRecord::Attachment.none_for_blob(persisted?)
      end

      def service
        self.class.services.fetch(service_name)
      end

      def mirror_later
        service.mirror_later(key, checksum: checksum) if service.respond_to?(:mirror_later)
      end

      def delete
        service.delete(key)
        service.delete_prefixed("variants/#{key}/") if image?
      end

      # Delete the metadata item and, when variant tracking is on, its variant
      # records. A still-referenced blob (attachments_count > 0) raises
      # ForeignKeyViolation via a strongly-consistent conditional delete.
      def destroy
        @previously_persisted = persisted?
        destroyed = false
        run_callbacks(:destroy) do
          # Guard on persisted? so a new/stamped blob object with a colliding id
          # cannot delete the stored blob's metadata.
          if persisted?
            delete_with_foreign_key_guard!
            destroyed = true
          end
        end
        if destroyed
          sweep_variant_records if ActiveStorage.track_variants
          run_callbacks(:commit)
        end
        destroyed
      end

      def purge
        destroy
        delete if previously_persisted?
      rescue ActiveStorage::ForeignKeyViolation
        nil
      end

      def purge_later
        ActiveStorage::PurgeJob.perform_later(self)
      end

      def previously_persisted?
        @previously_persisted
      end

      private

      # Conditional delete on the blob's own item: succeeds only when no
      # attachment references it. The count lives on this item and is mutated
      # atomically with each attachment write, so the guard is strong.
      def delete_with_foreign_key_guard!
        delete!(
          condition_expression: 'attribute_not_exists(#c) OR #c = :zero',
          expression_attribute_names: { '#c' => 'as_attachments_count' },
          expression_attribute_values: { ':zero' => 0 }
        )
      rescue Aws::DynamoDB::Errors::ConditionalCheckFailedException
        raise ActiveStorage::ForeignKeyViolation
      end

      # Destroy the blob's variant records. In Mode A this is a strong base-table
      # query, so the sweep sees every variant. In Mode B (numeric range key) the
      # listing comes from the eventually-consistent GSI — a variant created
      # within the GSI's propagation window of this purge may be missed (a benign,
      # documented limitation of the numeric-range fallback; the H2 ConditionCheck
      # still prevents creating a variant *after* the blob row is gone).
      def sweep_variant_records
        ActiveStorage::AwsRecord::VariantRecord.where_blob(id).each(&:destroy)
      end

      def indifferent_metadata
        (metadata || {}).each_with_object({}) { |(k, v), acc| acc[k.to_sym] = v }
      end

      def metadata_set(key, value)
        h = (metadata || {}).each_with_object({}) { |(k, v), acc| acc[k.to_s] = v }
        h[key.to_s] = value
        self.metadata = h
      end

      def open_local_io(tmpdir:)
        Tempfile.open(["ActiveStorage-#{id}-", filename.extension_with_delimiter], tmpdir) do |file|
          file.binmode
          local_io.rewind if local_io.respond_to?(:rewind)
          IO.copy_stream(local_io, file)
          local_io.rewind if local_io.respond_to?(:rewind)
          file.rewind
          yield file
        end
      end

      def default_variant_transformations
        { format: default_variant_format }
      end

      def default_variant_format
        if ActiveStorage.web_image_content_types.include?(content_type)
          filename.extension.presence || :png
        else
          :png
        end
      end

      def variant_class
        ActiveStorage.track_variants ? ActiveStorage::VariantWithRecord : ActiveStorage::Variant
      end
    end
  end
end
