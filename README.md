# activestorage-aws-record

Run **Active Storage on Amazon DynamoDB** — via [`aws-record`](https://github.com/aws/aws-record-ruby)
instead of Active Record.

It is a **metadata** backend: blob *bytes* still flow through a normal Active
Storage `Service` (Disk, S3, Mirror, …); only the Blob, Attachment, and
VariantRecord **metadata** lives in DynamoDB. Everything else — analyzers,
previewers, variants, jobs, direct uploads, controllers — is reused from Active
Storage unchanged.

It implements Active Storage's generic (non-ActiveRecord) custom-backend
contract, and doubles as a reference **example implementation** of that contract.

## Why

Apps built on DynamoDB + `aws-record` (no relational database) still want
Active Storage's attachment ergonomics. This gem provides them without
introducing Active Record, following **Single Table Design**: every Active
Storage item lives in *one* table you already own.

## Highlights

- **Single Table Design** — Blob, Attachment, and VariantRecord items share one
  application-provided table, keyed by `#`-separated composite keys under a
  configurable namespace. No gem-owned tables.
- **Zero-config key discovery** — the partition/sort key attribute names and
  types are auto-detected from the live table at boot. Usually the only thing
  you configure is the table name.
- **Adapts to your key types** — a **String** range key needs no GSI (all reads
  strongly consistent); a **numeric** range key is supported automatically by
  routing the adjacency through a string-keyed GSI.
- **Safe shared blobs** — a strongly-consistent, transactional reference count
  with a conditional-delete foreign-key guard (no wrongful purge of a shared
  blob, no zombie/orphan rows).
- **Atomic multi-attachment changes** — clearing, replacing, or detaching a
  `has_many` commits every row delete (and a coalesced refcount decrement per
  blob) in one DynamoDB transaction, so it can never delete some rows and leave
  others. A change over DynamoDB's 100-action limit fails closed rather than
  partially.
- **Fiber-safe** — Falcon-ready: eager mutex, mutex-guarded client, read-only
  post-boot schema cache.

## Requirements

- Ruby `>= 3.4`
- Active Storage with **generic custom-backend support** — currently the
  [`rails/rails#57537`](https://github.com/rails/rails/pull/57537) branch (not yet
  released). Until it ships in a Rails release, point your `Gemfile` at that
  branch; installing against a released `activestorage` will not work.
- `aws-record ~> 2.15`, `aws-sdk-dynamodb ~> 1`
- A DynamoDB table with a composite primary key (partition **String** + sort key)

## Installation

```ruby
# Gemfile
gem "activestorage-aws-record"
```

## Configuration

In a Rails app, configure via `config.activestorage_aws_record` (e.g. in
`config/application.rb` or an initializer):

```ruby
config.activestorage_aws_record.table_name = "my_app"        # the single table (required)
config.activestorage_aws_record.namespace  = "ActiveStorage" # key prefix; change to avoid collisions
# Optional:
# config.activestorage_aws_record.separator     = "#"
# config.activestorage_aws_record.client_options = { region: "eu-central-1" }
# config.activestorage_aws_record.client         = Aws::DynamoDB::Client.new(...)
# config.activestorage_aws_record.manage_table   = Rails.env.local?  # create the table if missing (dev/test)
# config.activestorage_aws_record.index_name     = "active_storage_index"  # which GSI to use in Mode B
```

| Setting | Default | Meaning |
|---|---|---|
| `table_name` | `"active_storage"` | The single shared table. |
| `namespace` | `"ActiveStorage"` | First segment of every key; isolates Active Storage items from your own. |
| `separator` | `"#"` | Key segment delimiter. |
| `client` / `client_options` | — / `{}` | Provide a client, or options for one. |
| `manage_table` | `false` | Create the table (and, in dev, point at it) if missing. Production tables are app-managed. |
| `index_name` | `"active_storage_index"` | The GSI to use when the range key is numeric (Mode B). |

The partition/sort key **attribute names** are *not* configured — they are
detected from the table.

## The table

The gem stores its items in your existing single table. It only assumes a
composite primary key: a **String partition key** and a sort key. The sort key's
type selects the mode automatically.

### Mode A — String sort key (recommended)

All access patterns live on the base table, so **every read is strongly
consistent and no GSI is required**. A minimal standalone table:

```ruby
client.create_table(
  table_name: "my_app",
  attribute_definitions: [
    { attribute_name: "pk", attribute_type: "S" },
    { attribute_name: "sk", attribute_type: "S" }
  ],
  key_schema: [
    { attribute_name: "pk", key_type: "HASH" },
    { attribute_name: "sk", key_type: "RANGE" }
  ],
  billing_mode: "PAY_PER_REQUEST"
)
```

(In development/test, `manage_table = true` creates exactly this for you.)

### Mode B — numeric sort key (e.g. a single-table app keyed `hash_key` + `version`)

A numeric sort key cannot hold the `#`-composite strings, so the gem routes
listing through a **string-keyed GSI** (auto-detected; its key names can be
anything). Point lookups, the reference count, and the foreign-key guard remain
**strong** on the base table; listing (an owner's attachments, a blob's variant
records) is **eventually consistent** via the GSI. Your table needs a GSI named
by `index_name` with a `(String, String)` key projecting `ALL`:

```ruby
global_secondary_indexes: [{
  index_name: "active_storage_index",
  key_schema: [
    { attribute_name: "as_index_pk", key_type: "HASH" },
    { attribute_name: "as_index_sk", key_type: "RANGE" }
  ],
  projection: { projection_type: "ALL" }
}]
```

If the range key is numeric and that GSI is missing, the gem raises a
`ConfigurationError` describing exactly what to add (it never mutates a
production table's indexes itself).

### Key layout

`ns` = `namespace`. Items are distinguished by key *values*, not separate tables:

| Entity | partition | sort |
|---|---|---|
| Blob | `ns#Blob#<id>` | `ns#Blob#<id>` |
| VariantRecord | `ns#Blob#<blob_id>` | `ns#VariantRecord#<digest>` |
| Attachment | `ns#Owner#<record_type>#<record_id>` | `ns#Attachment#<name>#<id>` |

All non-key attributes are stored under namespaced names (`as_filename`,
`as_blob_id`, …) so they never collide with your table's own key attributes.

## Usage

### Greenfield model — `Owner`

For an `aws-record` model with **no persistence of its own**, include `Owner`. It
provides an aws-record save/destroy wired into Active Storage's callbacks, plus
all the contract glue. Include `Aws::Record` **before** `Owner`:

```ruby
class User
  include Aws::Record
  include ActiveStorage::AwsRecord::Owner

  string_attr :id, hash_key: true
  string_attr :name

  has_one_attached :avatar
  has_many_attached :documents
end
```

### Model with its own persistence — `Attachable`

If your model **already** defines `save`/`destroy` (its own versioning, events,
search — e.g. a shared `BaseModel`), do **not** include `Owner` — it would
override that persistence. Include `Attachable` instead: it adds only the contract
glue (callback chains, a `changed?` bridge, owner resolution, the attachment
macros) and never touches your `save`/`destroy`. Your persistence just needs to
run Active Storage's callback chains — wrap it with the provided helpers:

```ruby
class Document < BaseModel            # BaseModel already defines save/destroy
  include ActiveStorage::AwsRecord::Attachable

  has_many_attached :files

  def save(*)    = run_attachment_save    { super }
  def destroy(*) = run_attachment_destroy { delete! if persisted? }
end
```

Active Storage resolves an owner from the bare id it stores; since aws-record's
`#find` is key-hash-based, `Attachable` supplies an `active_storage_find(id)`
adapter for that — without shadowing your model's own `#find`. Owners must be
single-hash-key. If you define `:commit` callbacks, you must run them (Active
Storage moves uploads to `after_commit` once they exist); with none, uploads
happen in `after_save`.

Then use Active Storage exactly as you would with the Active Record backend:

```ruby
user.avatar.attach(io: file, filename: "me.png", content_type: "image/png")
user.avatar.attached?         # => true
user.avatar.url               # served by your configured Service
user.documents.attach(blob1, blob2)
user.avatar.variant(resize_to_limit: [100, 100]).processed
```

Owners keep **their own** key schema — the single-table key scheme above applies
only to the gem's three entities.

## Consistency

- **Mode A**: every read is strongly consistent (base table only).
- **Mode B**: point lookups, the reference count, and the foreign-key guard are
  strong; *listing* (owner→attachments, blob→variant sweep) is eventually
  consistent (GSI). Active Storage's in-memory change tracking masks this within
  a request.

### Atomic grouped changes

Active Storage drives a `has_many` clear/replace/detach through
`attachment_class.transaction`. The adapter makes that a real, fiber-local
DynamoDB transaction: every row delete and a single **coalesced** `ADD` per blob
(so the same blob attached twice produces one `-2`, not two rejected ops) commit
in one `transact_write_items`. Either all rows go or none do — no partial clear.
*Creates stay per-row and synchronous*, so Active Storage's own failed-save
cleanup of new blob/attachment records is unaffected. A single buffered delete
keeps the per-row idempotent recovery (duplicate purge, orphaned blob).

## Known limitations

- `Blob#attachments` (the blob→attachment reverse lookup) is unsupported on a
  persisted blob — the design is deliberately GSI-free for that direction; the
  shared-blob count answers "is this still referenced?". Active Storage's generic
  path only reaches it for a non-persisted blob (which has no rows).
- Mode B variant cleanup uses the eventually-consistent GSI, so a variant created
  within the GSI's propagation window of a blob purge may be missed (Mode A is
  strong).
- Two requests processing the *same* variant concurrently can briefly see the
  variant record before its image is uploaded — a transient that resolves once
  the winner finishes (inherent to create-then-upload).
- Blob service keys are random 145-bit tokens; like the reference backend there
  is no DB-level unique-key constraint (collision is negligible).
- An atomic grouped change is capped by DynamoDB's **100-action** transaction
  limit (`#rows + #distinct blobs`). A larger clear/replace/detach raises
  `ActiveStorage::AwsRecord::TransactionTooLarge` **before any write** rather than
  chunking (which would reintroduce the partial-clear bug) — split it into
  smaller batches.
- A `has_one` *replace* is a synchronous create plus one buffered orphan delete.
  It is fully atomic only on an Active Storage that carries the widened
  `CreateOne#save` rescue (wrapping the whole `attachment_class.transaction`, so a
  commit-time delete failure rolls back the new record) — shipped together with
  this adapter as part of the generic-backend work. Without it, a transient
  failure on the old-blob delete can leave the new attachment plus an unpurged old
  blob.

## Development

```bash
bin/setup                  # bundle install + start DynamoDB Local (docker compose)
bundle exec rake test      # Minitest suite (Mode A)
bundle exec rake smoke     # standalone end-to-end smoke scripts (Mode A, Mode B, schema discovery)
bundle exec rake rubocop   # lint (Rails Omakase); `rake rubocop:autocorrect` to format
bundle exec rake build     # package the gem into pkg/
```

The suite talks to DynamoDB Local over `DYNAMODB_ENDPOINT` (default
`http://localhost:8000`). To use a different instance — e.g. to avoid clashing
with another DynamoDB Local already on `:8000`:

```bash
DYNAMODB_PORT=8002 docker compose up -d
DYNAMODB_ENDPOINT=http://localhost:8002 bundle exec rake test
```

It isolates itself with a per-process table name and never touches other tables
on the endpoint.

See [`PLAN.md`](PLAN.md) for the full design rationale.

## License

[MIT](LICENSE).
