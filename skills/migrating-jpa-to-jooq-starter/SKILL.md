---
name: migrating-jpa-to-jooq-starter
description: Use when migrating a Spring Data JPA `@Entity`/`JpaRepository` to jOOQ's `org.dema.jooq.AbstractRepository` (the `io.github.denis-markushin:jooq-starter` library), or when debugging `UninitializedPropertyAccessException: lateinit property dsl` from a jOOQ repository, or a `PRIMARY KEY`/unique-constraint violation from a jOOQ `save()` that used to work fine as a JPA `.save()`.
---

# Migrating from Spring Data JPA to jOOQ (`jooq-starter`)

## Overview

Replaces a Spring Data JPA `@Entity`/`JpaRepository` pair with a plain
immutable data class + a `org.dema.jooq.AbstractRepository` subclass. Proven
across 11 repositories in one real migration of a SQLite-backed service.
The mechanical rewrite is easy; the pitfalls below are not
obvious from the library's README, and each one caused a real bug in that
migration — one (Pitfall 3) reached the final whole-branch review only after
10 other repositories had already been individually reviewed and approved.

**Dialect scope:** Pitfalls 2–5 are jOOQ/`AbstractRepository` mechanics —
true on any backend (Postgres, MySQL, SQLite). Pitfall 1's *epoch-seconds*
detail is specific to SQLite's lack of a native timestamp type; a
Postgres-backed migration will typically have real `TIMESTAMP`/`TIMESTAMPTZ`
columns that jOOQ maps straight to `LocalDateTime`/`OffsetDateTime` with no
manual conversion at all. The broader lesson in Pitfall 1 — trust the
generated record over the old JPA annotations — still applies regardless of
dialect.

## Core pattern

A repository keyed by a natural key (`tags.name`, generated as `String` PK;
`usage_count` generated `Integer`), showing Pitfalls 1, 2, 3, and 4 together
— verified working end-to-end (a fresh agent given only this skill produced
equivalent code and it passed its own integration test):

```kotlin
data class TagEntry(
    val name: String,
    val color: String,
    val usageCount: Int = 0,
)

@Repository
class TagRepository : AbstractRepository<Tags, TagsRecord>(TAGS) {

    // Pitfall 3: natural-key PK, so save() must check existence, not "id == 0"
    fun save(entry: TagEntry): TagEntry {
        val record = getOneBy { it.NAME.eq(entry.name) }?.apply {
            // Pitfall 2: mutating a *fetched* record, then store()-ing it,
            // correctly UPDATEs — this is not the same as newRec()+store().
            color = entry.color
            usageCount = entry.usageCount
        } ?: newRec().apply {
            name = entry.name
            color = entry.color
            usageCount = entry.usageCount
        }
        store(record)
        return record.toEntry()
    }

    // Pitfall 4: a real method the repository declares, so callers (tests
    // included) never invoke the inherited final getOneBy directly.
    fun findByName(name: String): TagEntry? = getOneBy { it.NAME.eq(name) }?.toEntry()

    // Pitfall 1: TagsRecord.getUsageCount() is boxed Integer; TagEntry.usageCount is Int.
    private fun TagsRecord.toEntry() = TagEntry(name = name, color = color, usageCount = usageCount ?: 0)
}
```

## Stages (each repository its own commit)

1. Read the REAL generated record class for the table
   (`build/generated/sources/jooq/.../records/XRecord.java`) before writing
   any code — see Pitfall 1.
2. Write a failing test against a real database (SQLite needs no
   Testcontainers; use whatever integration-test base class the project
   already has).
3. Strip JPA annotations from the entity; make it an immutable `data class`.
4. Rewrite the repository extending `AbstractRepository<T, R>`. Use
   `getOneBy`/`getAllBy`/`deleteBy` for anything they can express; drop to
   raw `dsl.select`/`dsl.update` only for joins, partial-field updates, or
   dialect-specific functions (e.g. bitwise ops).
5. Fix every call site the rewrite breaks (grep the whole repo for the old
   class names) — budget real time here, it's usually the largest part of
   the task.
6. Run the FULL test suite, not just this repository's own test — see the
   traps table below.

## Pitfall 1: trust the generated record class, not the JPA entity's `@Column` types

jOOQ codegen reflects the REAL database column types, which routinely
disagree with what the JPA entity implies:

- Integer PK/FK columns come back as `Integer`, not `Long`, even when the
  domain model and most callers use `Long`. Keep the domain type `Long`,
  convert `.toInt()` / `(x ?: 0).toLong()` at the repository boundary.
- Timestamp columns declared `INT`/`INTEGER` often store epoch-*seconds*,
  not millis and not a temporal type — a 32-bit column can't hold
  millis-since-epoch for a modern date (overflows after ~24.8 days), which
  is itself a good sanity check when unsure. Convert explicitly
  (`/1000`+`.toInt()` on write, `*1000` on read for `Date`;
  `toEpochSecond(ZoneOffset.UTC)` / `ofEpochSecond(...)` for
  `LocalDateTime`/`OffsetDateTime`). Columns typed `TEXT` for a timestamp are
  the exception — plain ISO-8601 strings, use `OffsetDateTime.parse`/
  `.toString()`, no numeric conversion.
- Don't assume the JPA entity's `@Column(name = ...)` even names the right
  column — a prior migration may have renamed it in the DB and nobody
  updated the annotation. The generated record's field names are ground
  truth.

**Do this instead:** open the generated `XRecord.java` and read every
setter's parameter type before writing the entity or repository.

Converting at the boundary is the right fix for the ordinary PK/FK case
above, but it is the wrong fix when the database genuinely stores wider than
codegen reports — SQLite `INTEGER` is 64-bit but jOOQ maps it to `Integer`,
so a `.toInt()` at the boundary silently truncates. For a column whose
values genuinely exceed 32 bits (a byte count, a size, an epoch-millisecond
timestamp), the fix is a codegen `forcedType`, not a cast and not a schema
change:

```kotlin
forcedTypes {
    forcedType {
        name = "BIGINT"
        includeExpression = ".*\\.order_total"
    }
}
```

The diagnostic: if the domain type is already `Long` and only the generated
record is `Integer`, that is the signal — codegen is narrowing, not the
schema.

## Pitfall 2: `store()` on a fresh record always INSERTs, even if you set an existing PK on it

`AbstractRepository.newRec()` returns a completely unattached record
(`dsl.newRecord(table)`) with no "original" values recorded. jOOQ's
insert-vs-update decision is based on whether a record was ever fetched from
the DB, not on whether a PK value happens to be set — so
`newRec().apply { id = existingId; ... }; store(record)` attempts an INSERT
with that id and throws a PK-constraint violation instead of updating the
existing row.

**Verified:** decompiling `AbstractRepository.store()` shows it's just
`dsl.batchStore(records).execute()` — a thin wrapper, no special-case logic
of its own for a manually-set id.

**Do this — and prefer it over hand-rolling `dsl.update(...)`:** fetch the
record first via `getOneBy { ... }`, mutate its fields, then call
`store(record)` on that *same* fetched instance. Because it *was* fetched,
jOOQ correctly detects the changed fields and issues an UPDATE.

**Verified empirically**, not just assumed from documentation: a throwaway
test doing exactly `getOneBy { it.KEY.eq(key) }` → mutate a field →
`store(record)` on an existing row updated it in place, no duplicate-row
error. Reach for raw `dsl.update(...).where(...)` only when you want a
partial update without the extra SELECT round-trip, or need to update a
batch of rows by a shared condition rather than one fetched record at a
time.

**Related, and probably the single most common issue in the whole
migration (hit in more than half the repositories):** even on an INSERT,
`store()`'s underlying call — `dsl.batchStore(records).execute()` — doesn't
reliably return the generated key back onto the record, *even* on a column
jOOQ codegen'd with `identity(true)`. A JDBC batch-mode limitation with some
drivers, not something `AbstractRepository` special-cases. If a caller needs
the new id back after an insert, fall back explicitly:
```kotlin
store(record)
record.id = dsl.lastID().toInt()  // store() doesn't populate it reliably
```

`lastID()` is fragile beyond the reliability gap above: `last_insert_rowid()`
is **connection-scoped**. With a connection pool, `store()` and `lastID()`
are two statements that can execute on two different connections, so the id
returned can belong to another transaction's row entirely. The pattern is
correct only inside a transaction, and nothing in the code enforces or
documents that — a future non-transactional caller gets a silently wrong id.

`returningResult` supersedes this fallback rather than patching it:

```kotlin
record.id = checkNotNull(
    dsl.insertInto(table)
        .set(record)
        .returningResult(ORDERS.ID)
        .fetchOne(ORDERS.ID),
) { "insert returned no generated id for the new order" }
```

This removes the connection-scoping invariant entirely. See
[[jooq-repository-pattern]] for the SQLite caveat that `returningResult` is
emulated rather than native there — the emulation runs on the same pinned
connection as the insert, which is exactly what makes it connection-safe.
Note `fetchOne` returns a nullable, so the `checkNotNull` wrapper is
required, not decorative.

## Pitfall 3: natural-key primary keys need an explicit existence check before `save()`

If the PK is a business key (e.g. a `configs.key` string column) rather than
a surrogate auto-increment id, "insert if `id == 0`, else update" doesn't
apply — there's no sentinel "unsaved" value for a caller-supplied key.
`save()` must check for an existing row first
(`getOneBy { it.KEY.eq(entry.key) } != null`) and branch to insert or update
accordingly, or every re-save of an existing key throws a PK-constraint
violation.

**This exact bug reached final whole-branch review** in the source
migration — 10 sibling repositories all got an upsert path for their own
mutable-row scenarios, but the one repository keyed by a natural string key
was missed until the very last review pass, because no per-task test
happened to re-save an existing key. Add a test that does exactly that —
save, then re-save the same key with a different value — for any repository
whose PK isn't a surrogate id.

**On Postgres, check `AbstractRepository.upsert(record)` first** — it exists
and does exactly this (`INSERT ... ON CONFLICT (pk) DO UPDATE SET ALL
EXCLUDED ... RETURNING (xmax = 0) AS _created`), which would make the manual
existence-check unnecessary. It's Postgres-only (`xmax` is a Postgres
system column with no SQLite equivalent, which is why the source migration
— SQLite-backed — couldn't use it and had to hand-roll the check instead).
`insertOnConflictDoNothing(record)` also exists and is `ON CONFLICT DO
NOTHING`, portable to SQLite too, useful for idempotent-insert scenarios
where you don't need the update half at all.

## Pitfall 4: never call `AbstractRepository`'s inherited methods from outside the repository class

`getOneBy`/`getAllBy`/`deleteBy`/`store`/`newRec` are compiled `final` in
the jooq-starter jar (Kotlin classes are final-by-default, and this library
ships pre-compiled, so no project-level allopen setting can retroactively
open them). If Spring wraps the `@Repository` bean in a CGLIB subclass proxy
for any reason — AOP advice such as `@Transactional` elsewhere in the app is
enough to trigger Spring Boot's default `proxyTargetClass=true` behavior;
**this is not specific to JPA/Hibernate** — calling one of these final
methods directly on the injected (proxied) reference, from a test, a
service, anywhere outside the repository class itself, executes on the raw,
un-autowired proxy instance and throws:

```
kotlin.UninitializedPropertyAccessException: lateinit property dsl has not been initialized
```

**Verified empirically, twice:** this reproduces identically both with and
without Spring Data JPA/Hibernate on the classpath at all — removing JPA
entirely did not make the workaround unnecessary, disproving the plausible
assumption that this was purely a JPA-exception-translation-proxy artifact.

**Do this instead:** always wrap a call to an inherited method in a method
the repository class itself declares — even a one-liner like
`fun deleteById(id: Long) = deleteBy { it.ID.eq(id) }`. Never call
`repository.getOneBy { ... }` / `repository.store(...)` / etc. from outside
the repository, including from tests — add a small repository method for
whatever the test needs to drive directly.

## Pitfall 5: a table with no primary key can't use `AbstractRepository` at all

If a join table has no PK/unique constraint, jOOQ generates a plain
`TableRecord`, not an `UpdatableRecord` — and
`AbstractRepository<T, R : UpdatableRecord<*>>`'s generic bound rejects it.
Inject `DSLContext` directly for that one table and write plain
parameterized `dsl.insertInto(...)`/`dsl.select(...)` calls instead; don't
add a PK to the schema just to fit the base class unless the task explicitly
calls for that change.

## Other known traps

| Trap | What to do |
|---|---|
| No Kotlin `value class` auto-unwrapping (unlike Hibernate, which unwraps automatically) | Encode/decode manually at the repository boundary (`.raw`/wrapping constructor) for every inline value class field. |
| Bitmask permission columns (custom JPQL dialect functions like `bitwise_or`/`invert`) | `DSL.bitOr`/`DSL.bitAnd`/`DSL.bitNot` translate directly; `x & ~y` (clear bits) = `bitAnd(x, bitNot(DSL.val(y)))`. |
| `@EntityGraph` eager-fetch replacement | Two round-trip queries (parent rows, then children `WHERE parent_id IN (...)`), grouped by parent id in Kotlin — not a JOIN/MULTISET, to avoid relying on unverified dialect-specific JSON-aggregation behavior. Batch it (fetch all children for the whole result set in one second query); never call it per-row. |
| `@Lock(PESSIMISTIC_WRITE)` | `.forUpdate()` without `.skipLocked()` if the dialect doesn't support it (e.g. SQLite via jOOQ OSS) — document this as intent, not a functional no-op, especially if the DB already serializes writers at a coarser level. |
| Per-task test runs pass but the whole suite later fails | Run the FULL suite (not just the repository's own test) after every single repository migration, not only at the end. In the source migration, narrow per-task verification let 3 cross-repository regressions (a stale `@Column` name after an unrelated rename, a missing generated-PK fallback, a test bypassing the real schema) go undetected for 4 tasks. |
| Removing the JPA/Hibernate dependency at the end | Remove `@EnableJpaRepositories`/`@EnableJpaAuditing`-style annotations *before* removing the `spring-boot-starter-data-jpa` dependency, or the app won't boot. Also grep for anything that only compiled because the JPA starter transitively pulled it in (e.g. `jakarta.transaction.Transactional` via `jakarta.transaction-api`) — it breaks silently once the starter is gone. |
| `getAllBy`'s ordering overload isn't offset pagination | `getAllBy(orderBy, seekValues, limit, where)` is keyset/seek-based (each call needs the *previous page's* sort-key values), not simple page-number pagination. For an ordinary `Pageable`-style page/size API, drop to raw `dsl.selectFrom(table).orderBy(...).limit(size).offset(page * size)` instead of forcing the built-in overload to do something it isn't shaped for. |
| `deleteBy { … }` does not compile | `deleteBy` is declared `vararg Function1<T, Condition>`, and Kotlin rejects trailing-lambda syntax against a vararg parameter. The parentheses in `deleteBy({ … })` are required, not redundant — a "cleanup" that removes them fails the build at every call site. |

## Verification

Write the test first (it should fail to compile against the old JPA shape),
rewrite, make it pass, then run the whole suite — not just the new test —
before considering the repository done. For a natural-key-PK repository
specifically, the test must include a re-save of an existing key, not just
a single insert-then-read.
