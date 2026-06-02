namespace :activestorage_aws_record do
  namespace :table do
    desc 'Create the Active Storage DynamoDB table'
    task create: :environment do
      ActiveStorage::AwsRecord::Tables.create!
      puts "Created/verified table: #{ActiveStorage::AwsRecord.config.table_name}"
    end

    desc 'Delete the Active Storage DynamoDB table'
    task delete: :environment do
      ActiveStorage::AwsRecord::Tables.delete!
      puts 'Deleted Active Storage DynamoDB table.'
    end
  end
end
