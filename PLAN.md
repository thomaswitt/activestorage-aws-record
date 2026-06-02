# activestorage-aws-record — Implementation Spec

## Context & goal

A Ruby gem that lets **Active Storage run on Amazon DynamoDB** (via
[`aws-record`](https://github.com/aws/aws-record-ruby)) instead of Active Record,
implementing the *generic custom-backend contract* from
`../rails/guides/source/active_storage_custom_backend.md` (the
`activestorage-backends` work). It is the canonical **example implementation**
of that contract and is meant to drop into existing aws-record apps.

**Scope:** *metadata* backend only. Blob **bytes** flow through a normal Active
Storage `Service` (`Disk`/`S3`/`Mirror`); only blob / attachment /
variant-record **metadata** lives in DynamoDB. The Service layer, analyzers,
previewers, variants, jobs, and controllers are reused from Active Storage
unchanged.

The design follows **Single Table Design**: every Active Storage item — blob,
attachment, variant record — lives in **one** DynamoDB table, addressed by
`#`-separated composite keys. The gem **auto-detects** the table's
partition/sort key attribute names and assumes as little as possible, so it
drops into an existing single-table application by configuration alone.

## Requirements

1. **Single Table Design.** One table holds all three entity types. No
   gem-owned tables.
2. **Minimal assumptions:** a single table, *a* hash-key attribute, and *a*
   range-key attribute — nothing about their names. Keys use the `#` separator
   pattern.
3. **Auto-detect** the partition/range key attribute names (and types) from the
   live table via `describe_table`; in the common case the app configures *only
   the table name*.
4. **No GSI when the range key is a String** — the base table's `(hash, range)`
   alone serves every access pattern (see *Why no blob→attachment index is
   needed*). When the range key is numeric, auto-configure a single GSI instead
   (see *Storage modes*).
5. **As flexible / configurable as possible.** Table name, key-attribute names
   (override of auto-detect), key namespace, and separator are all settable.
   Don't hardcode host-app conventions (e.g. a project-specific `compose_key`
   delimiter); a private `#`-join with non-blank validation is enough.
6. **Fiber-safe (Falcon):** no `||=` on shared mutable state, eager `Mutex`,
   mutex-guarded client repository, `Fiber[]` over `Thread.current`, no `@@`,
   no blocking `sleep`, lambda defaults for `map_attr`.
7. **Coding guidelines:** no `# frozen_string_literal: true` magic comment,
   Ruby 3.4 idioms (`it`, hash shorthand, single quotes, keyword args), YARD on
   public methods, never SCAN a request path, mandatory expression aliasing on
   every DynamoDB expression.

## Dependencies & versioning

- `activestorage` **with generic custom-backend support** (the
  `activestorage-backends` branch / future Rails ≥ 8.1). Dev/test `Gemfile`
  path-references `../rails/*`.
- `aws-record ~> 2.15`, `aws-sdk-dynamodb ~> 1`.
- Transitive: `activemodel`, `activejob`, `activesupport`, `actionpack`,
  `globalid`. Ruby `>= 3.4`.

## Gem layout

```
lib/
  activestorage-aws-record.rb
  active_storage/aws_record.rb            # module, config, client repo, install!, schema discovery
  active_storage/aws_record/version.rb
  active_storage/aws_record/configuration.rb
  active_storage/aws_record/railtie.rb    # class wiring + Services + client
  active_storage/aws_record/persistence.rb# shared Aws::Record concern + key attrs + key helpers
  active_storage/aws_record/relation.rb   # DynamoDB-backed Relation
  active_storage/aws_record/blob.rb
  active_storage/aws_record/attachment.rb
  active_storage/aws_record/variant_record.rb
  active_storage/aws_record/owner.rb      # app-model concern (callback layer)
  active_storage/aws_record/tables.rb     # dev/test single-table helper (create/delete)
  active_storage/aws_record/tasks.rake
test/ (minitest, DynamoDB Local via docker-compose)
```

## Configuration (`ActiveStorage::AwsRecord::Configuration`)

| setting | default | meaning |
|---|---|---|
| `table_name` | `"active_storage"` | the single shared table |
| `partition_key` | `nil` → auto-detect | hash-key **DB attribute name** (override of `describe_table`) |
| `sort_key` | `nil` → auto-detect | range-key **DB attribute name** (override) |
| `namespace` | `"ActiveStorage"` | first segment of every key; isolates AS items from app items |
| `separator` | `"#"` | key segment delimiter |
| `index_name` | `"active_storage_index"` | GSI used when the range key is numeric (Mode B) |
| `index_partition_key` | `"as_index_pk"` | GSI hash-key DB attribute name (Mode B) |
| `index_sort_key` | `"as_index_sk"` | GSI range-key DB attribute name (Mode B) |
| `client` | `nil` | explicit `Aws::DynamoDB::Client` (else built from `client_options`) |
| `client_options` | `{}` | forwarded to `Aws::DynamoDB::Client.new` (`:region`, `:endpoint`, creds…) |
| `manage_table` | `false` (`true` in dev/test) | create the table (and GSI) if missing |

## Storage modes & schema auto-detection

The gem adapts to the table's existing key schema, detected **once at boot**
(`ActiveStorage::AwsRecord.discover_schema!`) via `describe_table(table_name)`:

- partition key = `key_schema` entry with `key_type == "HASH"` → its `attribute_name`,
- sort key = entry with `key_type == "RANGE"` → its `attribute_name`,
- types from `attribute_definitions`.

A `partition_key`/`sort_key` set in config overrides discovery. Discovery runs
once at boot and is cached in module state (read-only thereafter → fiber-safe).

The **range key's type** selects one of two physical layouts. The *logical* key
scheme is identical in both; only the mapping onto physical attributes differs.
The **partition (hash) key must be type `S` in both modes** (it stores
string keys); a numeric hash key, or a table with no range key, raises a clear
`ConfigurationError`.

### Logical keys (per entity)

Every item computes the same three strings — `H` (partition), `R` (sort), and a
globally-unique `item_id`. Let `ns` = `namespace` (default `ActiveStorage`),
`sep` = `separator` (`#`).

| Entity | `H` | `R` | `item_id` |
|---|---|---|---|
| **Blob** | `ns#Blob#<blob_id>` | `ns#Blob#<blob_id>` | `ns#Blob#<blob_id>` |
| **VariantRecord** | `ns#Blob#<blob_id>` | `ns#VariantRecord#<digest>` | `ns#Blob#<blob_id>#VariantRecord#<digest>` |
| **Attachment** | `ns#Owner#<record_type>#<record_id>` | `ns#Attachment#<name>#<attachment_id>` | `ns#Attachment#<attachment_id>` |

Keys are built with `AwsRecord.key(*parts)` = `parts.join(separator)` after
validating each part is non-blank.

### Mode A — string range key → base-table adjacency, no GSI

- Physical partition attr ← `H`, physical sort attr ← `R`.
- A blob and all its variant records **share one partition** (`ns#Blob#<id>`) —
  a textbook single-table *item collection*, fetched in one Query.
- Attachments are **grouped under their owner** (`ns#Owner#<type>#<id>`), because
  the contract's hot path is *owner → its attachments*.
- Every read is on the base table → **strongly consistent**.

### Mode B — numeric range key → string-keyed GSI adjacency

- Physical partition attr ← `item_id`, physical sort attr ← `0` (the required
  numeric range value; a constant).
- A GSI (`index_partition_key`/`index_sort_key`, both string, projection ALL)
  carries the adjacency pair: `index_partition ← H`, `index_sort ← R`.
- **Point lookups** (`Blob.find`, variant `find_by`) → base-table
  `GetItem(item_id, 0)` → strong.
- **Listing** (owner → attachments, variant sweep) → GSI Query → eventually
  consistent. Within a single request this is masked by Active Storage's
  in-memory change tracking.
- **Writes / refcount / FK-guard** → always base-table by `(item_id, 0)` →
  strong, so the shared-blob integrity guard is identical to Mode A.
- **GSI provisioning:** at boot, if the named GSI exists → use it; if missing
  and `manage_table` (dev/test) → create it (at table-create time or via
  `UpdateTable`); if missing in production → raise `ConfigurationError` with the
  exact GSI spec to add. The gem will not silently mutate a production table's
  indexes.

The Persistence concern and Relation read the detected mode to route
key-stamping and queries; all other behavior (blob/attachment/variant logic,
callbacks, refcount) is mode-agnostic.

### Access patterns

| Contract need | DynamoDB op | Key | Routing |
|---|---|---|---|
| `Blob.find(id)` | GetItem | blob item | base table, strong (both modes) |
| `Blob#destroy` FK guard | conditional DeleteItem | blob item, `attachments_count = 0 OR not_exists` | base table, strong |
| variant `find_by(digest)` | GetItem | variant item | base table, strong |
| `Blob#destroy` variant sweep | Query | `H=ns#Blob#blob_id`, `begins_with(R, "ns#VariantRecord#")` | base (A) / GSI (B) |
| owner → one named attachment | Query (limit 1) | `H=ns#Owner#type#id`, `begins_with(R, "ns#Attachment#name#")` | base (A) / GSI (B) |
| owner → all of a name | Query | same `begins_with` | base (A) / GSI (B) |
| owner → all attachments (destroy) | Query | `H=ns#Owner#type#id`, `begins_with(R, "ns#Attachment#")` | base (A) / GSI (B) |
| attachment → blob | GetItem | `blob_id` stored on the attachment item | base table, strong |
| refcount on attach/detach | `transact_write_items` | Put/Delete attachment **+** Update blob `ADD attachments_count :n` | base table, strong |

`record_type` may contain `::` but never `#`; ids/uuids never contain `#`; so
every `begins_with` is unambiguous.

### Why no blob→attachment index is needed

The only blob→attachment reverse query in the **generic** (non-AR) path is
`create_one_of_many.rb:14` `blob.attachments.find { … }`, reached **only in the
`else` branch where `blob.persisted? == false`** (line 11). A non-persisted blob
has zero attachment rows, so `Blob#attachments` can safely return `[]` there.
The persisted branch (line 12) goes through `record.{name}_attachments` — an
*owner* query. The shared-blob "is this still referenced?" question is answered
by the strongly-consistent `attachments_count` on the blob item, not by a
reverse query. So **no blob→attachment index is required**: Mode A is fully
GSI-free, and Mode B's single GSI exists only to provide string-keyed adjacency
on a numeric-range table, not to serve a reverse lookup. `Blob#attachments` is
implemented to return an empty, `QueryNotSupported`-on-materialize collection
(only ever hit pre-persist).

## Consistency & integrity model

Point lookups, writes, the refcount guard, and the FK-guard are always on the
base table and **strongly consistent in both modes**. Listing queries are strong
in Mode A and eventually consistent in Mode B (GSI), where in-request staleness
is masked by Active Storage's in-memory change tracking.

### Shared-blob foreign-key guard

The `ActiveStorage::ForeignKeyViolation` guard for shared blobs:

- `Attachment#save!` (create) = `transact_write_items` { Put attachment
  (`attribute_not_exists`), Update blob `ADD attachments_count 1` }.
- `Attachment#destroy` = `transact_write_items` { Delete attachment, Update blob
  `ADD attachments_count -1` }.
- `Blob#destroy` = conditional DeleteItem (`attachments_count = :zero OR
  attribute_not_exists(attachments_count)`); `ConditionalCheckFailed` ⇒ raise
  `ForeignKeyViolation`. The count is mutated atomically with each attachment
  write, so no concurrent attach is missed ⇒ no wrongful purge.

### Integrity & hardening rules

- **Count updates can't resurrect a purged blob.** Every transactional blob
  count `Update` carries `condition_expression: attribute_exists(#h)` (aliased),
  so an `ADD` against a purged blob fails the transaction → `RecordNotSaved`,
  never a count-only zombie item.
- **No double-decrement.** The attachment `Delete` in the destroy transaction
  carries `attribute_exists(#h)`; a duplicate purge fails the transaction (no
  second `ADD -1`). `Attachment#destroy`/`#delete` treat the conditional failure
  on an already-absent row as an idempotent no-op rather than re-decrementing.
- **`delete` decrements too.** Both `destroy` and `delete` go through the
  transactional refcount path; `delete` only skips `touch`/blob cleanup.
- **Attachment row identity.** `has_one` replaces (delete-old-then-create), so no
  storage-level uniqueness is required there; `has_many` intentionally permits
  the same blob attached twice (matches the reference `in_memory_backend`). The
  uuid-suffixed `R` is kept; no uniqueness constraint the contract doesn't
  require is invented.
- **Variant vs. blob-purge race.** `VariantRecord.create_or_find_by!` adds a
  `ConditionCheck attribute_exists` on the blob root in the same
  `transact_write_items` as the conditional variant `Put`, so a variant cannot
  be created against a just-purged blob. `Blob#destroy` deletes the blob root
  (conditional on `count == 0`) **before** sweeping variants.
- **Attribute name isolation.** Every **non-key** logical attribute is declared
  with an explicit namespaced `database_attribute_name` (`as_blob_id`,
  `as_filename`, `as_record_type`, …) so it can never clash with a detected key
  attribute named `id`/`blob_id`/`sk`/etc. Key attrs use the detected DB names.
- **Key types.** Discovery requires partition `S` (both modes); range `S`
  selects Mode A, range `N` selects Mode B; anything else (numeric partition, no
  range key) → `ConfigurationError`.
- **`Blob#attachments` on a persisted blob** is not supported without a
  blob-keyed index. The generic contract never calls it there (only the
  non-persisted dedup branch, which returns `[]`); materializing it on a
  persisted blob raises `QueryNotSupported` — a documented limitation.
- **Namespace/separator validation.** Reject a blank `namespace`/`separator`, and
  validate that `record_type`/`record_id`/`name` contain no `separator` before
  building keys → no `begins_with` bleed.

## Persistence concern (`Persistence`) — shared key plumbing

`include Aws::Record` + `GlobalID::Identification`. Declares the **two key
attributes once**, with auto-detected/overridden DB names, applied at
`install!` (after schema discovery), not in the class body:

```ruby
model.set_table_name(config.table_name)
model.string_attr :dynamo_partition_key, hash_key: true,  database_attribute_name: schema.partition_key
model.string_attr :dynamo_range_key,     range_key: true, database_attribute_name: schema.sort_key
```

In Mode A these map to the detected `H`/`R` attributes; in Mode B the base-table
keys map to `item_id` and the numeric constant, while `H`/`R` are stamped onto
the GSI attributes. Internal Ruby accessors `dynamo_partition_key` /
`dynamo_range_key` are gem-private (never collide with entity attrs). Each entity
stamps its key attributes from its own logical id(s) before every write.

The concern also provides: `read_attribute`/`write_attribute` via `@data`;
`==`/`eql?`/`hash` by class + logical id; `changed?` → aws-record `dirty?`;
`dynamodb_client` delegation; persist-state helpers (`mark_persisted!`/
`mark_destroyed!` via `@data`). `find(id)` is **not** in the concern (each entity
composes its own key).

## Contract method mapping

### `Blob`

Mirrors the in-memory reference Blob; includes only `Servable`.

- `find(id)` → GetItem on the blob item; raise `RecordNotFound` on nil.
- stamps its key attributes from `id` before save.
- `attachments` → empty collection (see *Why no blob→attachment index is
  needed*).
- `destroy` FK guard = conditional DeleteItem by key; variant sweep =
  `VariantRecord.where_blob(id)`.
- `map_attr :metadata, default_value: -> { {} }` (fiber-safe lambda default).

### `Attachment`

- `H = key(ns, "Owner", record_type, record_id)`,
  `R = key(ns, "Attachment", name, id)`, `item_id = key(ns, "Attachment", id)`.
- `transactional_create!`/`transactional_destroy!` use `transact_write_items`
  with the blob's key for the `ADD` update; expression-aliased.
- `where`/`find_by` via `Relation` (owner query).
- Both `destroy` and `delete` decrement the refcount through the transactional
  path; `delete` simply skips `touch`/blob cleanup. Replace/detach paths stay
  correct.

### `VariantRecord`

- `H = key(ns, "Blob", blob_id)`, `R = key(ns, "VariantRecord", digest)`,
  `item_id = key(ns, "Blob", blob_id, "VariantRecord", digest)`.
- `find(id)` decodes the reversible Base64 id → `(blob_id, digest)` → GetItem.
- `create_or_find_by!` = conditional Put (`attribute_not_exists`) +
  blob-existence `ConditionCheck` + find-on-conflict.
- `where_blob(blob_id)` = Query `H=ns#Blob#blob_id`,
  `begins_with(R, "ns#VariantRecord#")`.
- Itself an Owner (`has_one_attached :image`); its image attachment lands under
  `ns#Owner#<VariantRecordClass>#<encoded_id>` (encoded id is `#`-free Base64).

### `Owner`

Callback layer over aws-record save/destroy/commit/rollback.

### `Relation`

`owner_query` (`begins_with` by name) is the sole listing path — strong in Mode
A, GSI-routed in Mode B. Unsupported filters raise `QueryNotSupported`. Key
building uses `Attachment` key helpers, not a raw delimiter constant.

## Module (`ActiveStorage::AwsRecord`) — fiber-safe client repository + discovery

```ruby
@client_mutex = Mutex.new        # eager, at load (fiber/thread-safe init)
@config       = Configuration.new

def self.dynamodb_client
  @client_mutex.synchronize { @dynamodb_client ||= config.client || Aws::DynamoDB::Client.new(config.client_options) }
end

def self.key(*parts)
  parts.each { raise ArgumentError, 'blank key segment' if it.nil? || it.to_s.empty? }
  parts.join(config.separator)
end
```

`install!`: discover schema (`discover_schema!`), declare key attrs + table name
on `Blob`/`Attachment`/`VariantRecord` (idempotent — skip if `hash_key` already
set), point them at the shared client. `install_attachments!`:
`Blob has_one_attached :preview_image`, `VariantRecord has_one_attached :image`.

## Railtie / configuration / Services

- before `active_storage.class_indirection`: set
  `blob/attachment/variant_record_class` + map
  `config.activestorage_aws_record.*` → `Configuration` (incl. `table_name`,
  `namespace`, `separator`, `partition_key`, `sort_key`, `index_*`,
  `client(_options)`).
- `config.after_initialize`: `install!` (discovers schema, declares key attrs),
  `Services.setup_from_app_config(app)`, `install_attachments!`.

## Table management (dev/test only; production tables are app-managed)

`Tables.create!`/`delete!`/`exist?` for **one** table: `{ H: S, R: S }`,
`PAY_PER_REQUEST`. Default key names `pk`/`sk` when the gem creates it; in Mode B
dev/test it also provisions the `active_storage_index` GSI. Production apps point
`table_name` at an existing table and the gem auto-detects whatever the key
attributes are called. Migrations are additive-only.

## Testing (DynamoDB Local via docker-compose)

`dynamo_setup` boots a minimal Rails app (no Active Record) + this gem against
DynamoDB Local; creates **one** disposable table per pid; `Disk` service for
bytes.

**Behavior suite:** attach/replace/detach/purge (sync + later), has_one/has_many,
direct upload + protected-metadata filtering, analyze (immediate/later/lazy),
variant tracking, owner destroy + dependent purge, abort/return-false destroy
keeps rows, never-saved colliding-id owner leaves victim intact, shared blob
purged once, signed-id round-trip, GlobalID job round-trip, concurrent
`create_or_find_by!` variant uniqueness.

**Schema / mode coverage:**
- (a) auto-detection picks up a table with non-default, string-range key
  attribute names (e.g. `hash_key`/`range_key`) → Mode A.
- (b) a numeric-range table → Mode B: the GSI is auto-configured and listing
  queries route through it.
- (c) a numeric *partition* key (or a table with no range key) → `ConfigurationError`.
- (d) all three entity types coexist in one table without key collision.
- (e) `Attachment#delete` decrements the refcount.

## Key design decisions

1. **One table, mode-selected layout.** String range key → base-table adjacency,
   no GSI; numeric range key → string-keyed GSI adjacency. Both keep strong
   refcount/FK-guard on the base table.
2. **The only reverse lookup is on a non-persisted blob** (returns `[]`);
   refcount replaces blob→attachment counting, so no reverse index is needed.
3. **Auto-detect keys** via `describe_table` at boot, with config override;
   partition key must be `S`, range key `S` or `N` selects the mode.
4. **Co-locate blob + variants**, group attachments under owner — idiomatic
   single-table item collections that serve every access pattern.
5. **`#`-join with non-blank validation**, not a host-app `compose_key`.
6. **Fiber safety** — eager mutex, mutex-guarded client repo, lambda map default,
   read-only post-boot schema cache.
7. **Style** — no `frozen_string_literal`, Ruby 3.4 idioms, YARD, expression
   aliasing, never SCAN a request path.
8. **Grouped destroys are atomic; creates stay per-row.** Each attachment
   *create* is its own 2-item transaction (attachment + blob refcount), so the
   generic create paths keep their synchronous failed-save cleanup. The generic
   `has_many` clear/replace/detach and `Relation#delete_all` paths wrap their
   per-row destroys in `Attachment.transaction`, a fiber-local accumulator that
   commits all the buffered deletes — and one *coalesced* `ADD` per distinct blob
   — in a single `transact_write_items`, so a multi-attachment change is atomic
   instead of deleting some rows before a later one fails. A change exceeding
   DynamoDB's 100-action transaction limit **fails closed** before any write
   (`TransactionTooLarge`) rather than chunking, which would reintroduce the
   partial-clear bug. A single buffered destroy still uses the per-row path, so
   its idempotent duplicate-purge / orphaned-blob recovery is preserved.
   *Mixed has_one replace* (a synchronous create plus one buffered orphan delete)
   is only fully atomic when the host Active Storage carries the widened
   `CreateOne#save` rescue (it wraps the whole `attachment_class.transaction`, so
   a commit-time delete failure rolls back the new record) — part of the same
   `activestorage-backends` work this gem targets.
