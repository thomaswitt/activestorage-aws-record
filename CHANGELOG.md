# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-06-02

Initial release. Companion to the Active Storage generic custom-backend contract
proposed in [`rails/rails#57537`](https://github.com/rails/rails/pull/57537);
until it ships in a Rails release, use this gem against that branch.

### Added

- Active Storage **metadata** backend on Amazon DynamoDB via
  [`aws-record`](https://github.com/aws/aws-record-ruby), implementing Rails' generic
  (non-ActiveRecord) custom-backend contract. Blob bytes still flow through a
  normal Active Storage Service (Disk/S3/Mirror); only Blob, Attachment, and
  VariantRecord metadata lives in DynamoDB.
- **Atomic multi-attachment changes**: a `has_many` clear/replace/detach commits
  every row delete and a coalesced reference-count decrement per blob in one
  DynamoDB transaction (fail-closed at DynamoDB's 100-action limit), so it can
  never delete some rows and leave others.
- **Single Table Design**: all three entity types live in one
  application-provided table, addressed by `#`-separated composite keys under a
  configurable namespace. No gem-owned tables.
- **Zero-configuration key discovery**: the partition/sort key attribute names
  and types are auto-detected from the live table via `describe_table` at boot.
  The only required setting is the table name.
- **Two storage modes, chosen automatically by the range key's type**:
  - *Mode A* (String range key) — adjacency keys live directly in the base
    table; every read is strongly consistent; no GSI.
  - *Mode B* (Number range key) — adjacency keys live in an auto-detected
    string-keyed GSI; point lookups, the reference count, and the foreign-key
    guard stay strong on the base table; listing is eventually consistent.
- Strongly-consistent shared-blob protection: a transactional reference count on
  the blob item, with a conditional-delete foreign-key guard
  (`ActiveStorage::ForeignKeyViolation`).
- Two owner concerns: `ActiveStorage::AwsRecord::Owner` for a greenfield
  `aws-record` model (persistence + contract glue), and
  `ActiveStorage::AwsRecord::Attachable` for a model that brings its own
  persistence (versioning/events/search) — contract glue only, without overriding
  `save`/`destroy`. Both enable `has_one_attached` / `has_many_attached`.
- Fiber-safe (Falcon-ready): eager mutex, mutex-guarded client repository,
  read-only post-boot schema cache, lambda `map_attr` defaults.
- Rails Railtie wiring, a development/test single-table manager, and in-app rake
  tasks (`activestorage_aws_record:table:create` / `:delete`).
- Standard gem tooling: a `Rakefile` (`rake test` / `rake smoke` / `rake build`),
  RuboCop config (Rails Omakase via `rubocop-rails-omakase` + `rubocop-rake`),
  `bin/console` + `bin/setup`, and a `docker-compose.yml` for DynamoDB Local.

[Unreleased]: https://github.com/thomaswitt/activestorage-aws-record/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/thomaswitt/activestorage-aws-record/releases/tag/v0.1.0
