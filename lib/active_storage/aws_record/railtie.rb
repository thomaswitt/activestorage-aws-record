require 'rails/railtie'

module ActiveStorage
  module AwsRecord
    # Wires the gem into a Rails app: maps +config.activestorage_aws_record+ onto
    # the gem's {Configuration}, registers the three classes as Active Storage's
    # persistence classes before class indirection resolves, then — once the app
    # is initialized — discovers the table layout and declares the models' key
    # attributes, sets up the service registry (the custom blob class does not
    # load the default Active Record blob that normally does this), and installs
    # the +preview_image+ / +image+ attachments.
    class Railtie < ::Rails::Railtie
      config.activestorage_aws_record = ActiveSupport::OrderedOptions.new

      initializer 'activestorage_aws_record.configure', before: 'active_storage.class_indirection' do |app|
        options = app.config.activestorage_aws_record

        ActiveStorage::AwsRecord.configure do |config|
          config.table_name     = options.table_name     if options.table_name
          config.namespace      = options.namespace      if options.namespace
          config.separator      = options.separator      if options.separator
          config.manage_table   = options.manage_table   unless options.manage_table.nil?
          config.index_name     = options.index_name     if options.index_name
          config.client_options = options.client_options if options.client_options
          config.client         = options.client         if options.client
        end

        app.config.active_storage.blob_class = 'ActiveStorage::AwsRecord::Blob'
        app.config.active_storage.attachment_class = 'ActiveStorage::AwsRecord::Attachment'
        app.config.active_storage.variant_record_class = 'ActiveStorage::AwsRecord::VariantRecord'
      end

      # Run after the app is fully initialized so Active Storage's app/models
      # (Servable, Variant, ...) are autoloadable when our model classes load.
      config.after_initialize do |app|
        # Discover the table layout and declare the models' key attributes +
        # shared client.
        ActiveStorage::AwsRecord.install!

        # The default AR blob initializes the service registry on load; the
        # custom backend must do it explicitly.
        ActiveStorage::Services.setup_from_app_config(app)

        # Install the owner attachments now that class indirection is configured.
        ActiveStorage::AwsRecord.install_attachments!
      end

      rake_tasks do
        load File.expand_path('tasks.rake', __dir__)
      end
    end
  end
end
