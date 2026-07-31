---
name: rust-sqlx-repository-pattern
description: Use when writing or reviewing database access in Rust with sqlx (or sea-orm) - repository structure, compile-time checked queries, migrations, transaction boundaries, soft delete, pagination, batching instead of N+1, offline mode in CI, and testing against a real PostgreSQL.
---

# sqlx Repository Pattern

## One repository per table

```rust
#[derive(Clone)]
pub struct OrderRepository {
    pool: PgPool,
}

impl OrderRepository {
    pub fn new(pool: PgPool) -> Self { Self { pool } }

    pub async fn find(&self, id: OrderId) -> Result<Option<Order>, sqlx::Error> {
        sqlx::query_as!(OrderRow, "select * from orders where id = $1 and deleted_at is null", id.0)
            .fetch_optional(&self.pool)
            .await
            .map(|row| row.map(Into::into))
    }
}
```

The rules that make this hold:

- **`PgPool` never leaves the repository layer.** A service that holds a pool
  will eventually write SQL in a handler, and then the same table is queried
  three different ways from three places. Services depend on named repository
  methods.
- **One repository per table**, named for the table. A `Database` struct with
  forty methods is the thing this pattern exists to prevent.
- Repository methods are named for the domain question they answer —
  `find_unpaid_older_than`, not `select_by_status_and_date`.
- `PgPool` is `Arc` inside; `#[derive(Clone)]` and clone it freely.
- Return `Result<Option<T>, sqlx::Error>` for a lookup. Collapsing "not found"
  into an error forces every caller to match an error variant for a normal
  outcome.

## Row types are not domain types

```rust
struct OrderRow {
    id: Uuid,
    status: String,
    total_cents: i64,
    created_at: OffsetDateTime,
}

impl TryFrom<OrderRow> for Order {
    type Error = OrderError;
    fn try_from(row: OrderRow) -> Result<Self, Self::Error> { ... }
}
```

The row mirrors the table — `i64` because PostgreSQL has no unsigned, `String`
because the column is text. The domain type has a `Money` and a `Status` enum.
Keeping them the same type couples the schema to the API and to the domain, so
a column rename becomes a wire-format break.

Skip the split only for a genuinely internal, three-column table with no
invariants — and expect to add it later.

## Compile-time checked queries

Prefer the macros (`query!`, `query_as!`, `query_scalar!`) over the functions.
They check the SQL against a live schema at **compile** time: a renamed column
is a build failure rather than a 500.

```rust
sqlx::query_as!(OrderRow, "select id, status, total_cents, created_at from orders where id = $1", id.0)
```

- Name the columns. `select *` on a macro means a new column changes the
  inferred struct and breaks the build for no reason.
- Type overrides where sqlx cannot infer: `status as "status: Status"` maps to
  a Rust enum, `count as "count!"` asserts a nullable-by-inference column is
  not null, `col as "col?"` forces the opposite.
- **CI needs offline mode.** Run `cargo sqlx prepare --workspace` and commit
  `.sqlx/` so the build does not need a database. A stale `.sqlx/` is a
  confusing compile error — regenerate it in the same commit as the migration,
  and verify it in CI with `cargo sqlx prepare --check`.
- Dynamic SQL cannot use the macros. Use `QueryBuilder` — never `format!`.
  String-interpolated SQL is a SQL injection, and no amount of "the input is
  internal" survives contact with a refactor:

```rust
let mut q = QueryBuilder::new("select id, status from orders where deleted_at is null");
if let Some(status) = filter.status {
    q.push(" and status = ").push_bind(status);
}
q.build_query_as::<OrderRow>().fetch_all(&self.pool).await
```

`push_bind` is the only way a value enters a query. `push` is for SQL
fragments you wrote yourself, never for a value.

## Always-on filters belong in the repository

Soft delete, tenant scoping, and archive filters get baked in once, not
repeated at every call site — one forgotten `and deleted_at is null` is a
data leak.

```rust
const ACTIVE: &str = " and deleted_at is null";
```

Expose an explicit escape hatch (`find_including_deleted`) where a caller
genuinely needs the filtered-out rows, so bypassing the filter is visible in
the call.

For multi-tenant data, prefer PostgreSQL row-level security over a predicate a
developer must remember — a `WHERE` clause is opt-in, RLS is not.

## Transactions

The boundary belongs to the **service**, not the repository, because only the
service knows which writes must be atomic. Repositories therefore take an
executor:

```rust
impl OrderRepository {
    pub async fn insert<'e, E: PgExecutor<'e>>(&self, tx: E, order: &Order) -> Result<(), sqlx::Error> {
        sqlx::query!("insert into orders (id, status, total_cents) values ($1, $2, $3)",
            order.id.0, order.status.as_str(), order.total.cents())
            .execute(tx).await.map(|_| ())
    }
}

let mut tx = pool.begin().await?;
orders.insert(&mut *tx, &order).await?;
outbox.enqueue(&mut *tx, OrderPlaced::from(&order)).await?;
tx.commit().await?;
```

- A dropped `Transaction` rolls back — including when the future is cancelled
  mid-request. That is the behavior you want; do not defeat it by committing
  early.
- **Nothing slow inside a transaction.** No HTTP call, no message publish, no
  waiting on a user. An open transaction holds locks and a pool connection;
  one slow external call inside one turns into pool exhaustion under load.
- To make a database write and a message publish atomic, use the **transactional
  outbox**: write the row and an `outbox` row in the same transaction, and let
  a relay publish. There is no other way to get both.
- Set an explicit `statement_timeout` and `lock_timeout` on the pool
  (`after_connect`), so a pathological query cannot hold a connection
  indefinitely.
- Reach for `select ... for update` (or `for update skip locked` in a queue
  worker) rather than a read-then-write race. State the isolation level when
  the correctness argument depends on it.

## No query inside a loop

The N+1 is the single most common production database bug, and in async Rust
it hides behind a clean-looking `for` with an `.await`:

```rust
for id in ids {
    orders.push(repo.find(id).await?);
}
```

Use the set form:

```rust
sqlx::query_as!(OrderRow, "select id, status from orders where id = any($1)", &ids[..])
```

`= any($1)` with a slice is the sqlx idiom for `IN`. For a bulk insert, `unnest`
turns arrays into rows in one statement:

```rust
sqlx::query!("insert into orders (id, status) select * from unnest($1::uuid[], $2::text[])", &ids, &statuses)
```

For a parent-and-children read, one query with a join beats a query per parent;
group in memory with `into_group_map_by`. Two round trips that stay constant
beat N that grow with the data — and a loop that fails halfway leaves
partially-applied state with no transaction around it.

## Pagination

Offset pagination degrades: `offset 10000` makes PostgreSQL walk and discard
10,000 rows, and a concurrent insert shifts the window so a row is returned
twice or skipped. Prefer keyset pagination for anything unbounded:

```rust
sqlx::query_as!(OrderRow,
    "select id, created_at from orders where deleted_at is null
       and (created_at, id) < ($1, $2)
     order by created_at desc, id desc limit $3",
    cursor.created_at, cursor.id, limit)
```

The tiebreaker column is not optional — ordering by a non-unique `created_at`
alone gives a non-deterministic page boundary.

Always cap `limit` server-side. A client asking for 10 million rows should get
the cap, not an OOM.

## Migrations

- `sqlx::migrate!()` embeds `migrations/` in the binary and runs them at
  startup, or run them as a separate deploy step for a multi-replica service —
  pick one deliberately, since concurrent startup migrations race.
- Migrations are **append-only and never edited** once merged. A fix is a new
  migration.
- Expand-contract for anything with live traffic: add the nullable column,
  backfill in batches, start writing both, switch reads, then drop the old
  column in a later release. A single migration that renames a column breaks
  every instance still running the old binary.
- Adding an index on a large table needs `create index concurrently` — outside
  a transaction, which means its own migration file, since sqlx wraps each
  migration in one by default.
- A `NOT NULL` column added with a default rewrites the table on PostgreSQL
  before 11; on 11+ it is fast, but the `NOT NULL` validation still needs a
  lock. Check the version and the table size before assuming it is free.
- Test the migration against a copy of production-sized data, not an empty
  schema. Every migration that took the site down passed on an empty database.

## The pool

```rust
PgPoolOptions::new()
    .max_connections(10)
    .acquire_timeout(Duration::from_secs(3))
    .test_before_acquire(true)
    .connect(&config.database_url).await
```

- Size the pool against the database's `max_connections` divided by the
  replica count, not by guessing. More connections is not more throughput —
  PostgreSQL degrades past its CPU count.
- `acquire_timeout` must be set. Without it, pool exhaustion presents as a hang
  rather than an error, and the metric you need does not exist.
- Build **one** pool per process and clone it. Never per request.
- `pool.close().await` during shutdown, so in-flight transactions finish
  instead of being severed.

## Testing

Test the query through the scenario that uses it, against a real PostgreSQL in
`testcontainers` — never SQLite, which differs on types, concurrency and
upsert semantics. A per-method repository test asserts the mapping you just
wrote, pins an implementation detail, and proves nothing about whether the
feature works.

Write a direct repository test only where a scenario cannot reach: a query-count
assertion pinning an N+1 fix, a branch reachable only from data no entry point
produces, or a write path with no read path — and that last one usually means
the write is dead code worth deleting.

Isolate tests by wrapping each in a transaction that is rolled back, or by
giving each its own schema, rather than starting a container per test. Details
in `rust-test-writing-rules`.

## sea-orm and diesel

Prefer `sqlx` by default: the SQL stays visible, the macros check it against
the real schema, and there is no query-builder dialect to learn.

Reach for `sea-orm` when a project genuinely needs runtime-dynamic queries
across many entities and relations, and accept that you lose compile-time SQL
checking. Reach for `diesel` when a synchronous, fully type-checked DSL is
worth its compile times and its learning curve. Whichever is chosen, the
repository boundary, the transaction rules, the N+1 rule and the migration
rules above are unchanged — they are not sqlx-specific.

## Reviewing database code

- Does a `PgPool` or raw SQL appear outside the repository layer?
- Is any SQL built with `format!` instead of `push_bind`?
- Is there an `.await`ed query inside a `for` loop?
- Does an unbounded list endpoint use `offset`, or paginate without a cap?
- Is an HTTP call or a publish inside a transaction?
- Is a soft-delete or tenant predicate repeated at call sites instead of baked in?
- Is `.sqlx/` regenerated in the same commit as the schema change?
- Does the migration rename or drop a column that a running binary still uses?
- Is `acquire_timeout` set, and is the pool built once?
