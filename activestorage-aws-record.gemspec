require_relative "lib/active_storage/aws_record/version"

Gem::Specification.new do |spec|
  spec.name        = "activestorage-aws-record"
  spec.version     = ActiveStorage::AwsRecord::VERSION
  spec.authors     = ["Thomas Witt"]
  spec.summary     = "Run Active Storage on Amazon DynamoDB via aws-record."
  spec.description = <<~DESC
    A metadata backend that lets Active Storage store its Blob, Attachment, and
    VariantRecord rows in Amazon DynamoDB (through the aws-record gem) instead of
    Active Record. Blob bytes still flow through any Active Storage Service
    (Disk, S3, ...); only the metadata lives in DynamoDB. Implements the generic
    custom Active Storage backend contract.
  DESC
  spec.homepage = "https://github.com/thomaswitt/activestorage-aws-record"
  spec.license  = "MIT"

  spec.required_ruby_version = ">= 3.4.0"

  spec.files = Dir[
    "lib/**/*.rb",
    "lib/**/*.rake",
    "README.md",
    "CHANGELOG.md",
    "LICENSE",
    "PLAN.md"
  ]
  spec.require_paths = ["lib"]

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "rubygems_mfa_required" => "true",
  }

  # Requires the generic custom-backend support added in the activestorage
  # "activestorage-backends" work (a future Rails). During development the
  # Gemfile path-references a local Rails checkout that provides it.
  spec.add_dependency "activestorage", ">= 8.1"
  spec.add_dependency "activejob", ">= 8.1"
  spec.add_dependency "activemodel", ">= 8.1"
  spec.add_dependency "activesupport", ">= 8.1"
  spec.add_dependency "aws-record", "~> 2.15"
  spec.add_dependency "aws-sdk-dynamodb", "~> 1"
  spec.add_dependency "globalid", ">= 1.0"
end
