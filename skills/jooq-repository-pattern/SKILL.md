---
name: jooq-repository-pattern
description: Use when writing or reviewing a jOOQ repository in a Spring Boot service built on `jooq-starter` (`org.dema.jooq.AbstractRepository`) — one repository per table, soft-delete via baseCondition, keeping DSLContext out of services, audit timestamps, Spring Data Page/Pageable results — or when configuring or debugging `jooqCodegen` generation from Liquibase migrations.
---

# jOOQ Repository Pattern (`jooq-starter`)

Conventions for jOOQ data access in Spring Boot services built on the
[common-libs](https://github.com/denis-markushin/common-libs) jOOQ libraries:
`jooq-starter` (repository base class, pagination, audit timestamps) and
`jooq-liquibase-testcontainer` (code generation).

Group ids and versions have moved between releases of these libraries. Check
common-libs for the current coordinates rather than copying the ones below
verbatim.

## 0. Generate code from Liquibase migrations via Testcontainers

The generator needs a real schema. Instead of maintaining separate DDL or
pointing codegen at a shared database that drifts, generate against a
disposable Postgres container with your Liquibase changelog applied. Migrations
stay the single source of truth, and a renamed column becomes a compile error
instead of a runtime one.

**Convention-plugin route** — the plugin bundles the wiring below:

```kotlin
plugins {
    id("io.github.denis-markushin.jooq-codegen")
}

demaJooq {
    databaseImage = "postgresql:17.5-alpine"
    configuration {
        generator {
            database {
                includes = "custom_.*"
            }
        }
    }
}
```

`databaseImage` is a Testcontainers image spec, not a raw Docker image name —
the plugin concatenates it into `jdbc:tc:$databaseImage:///...`, which is why it
reads `postgresql:...` (the Testcontainers JDBC scheme) rather than `postgres:...`.

**Manual route** — the stock jOOQ Gradle plugin plus the Testcontainers-backed
`Database` implementation:

```kotlin
plugins {
    id("org.jooq.jooq-codegen-gradle")
}

dependencies {
    jooqCodegen("org.dema:jooq-liquibase-testcontainer:x.x.x")
}

jooq {
    configuration {
        jdbc {
            driver = "org.testcontainers.jdbc.ContainerDatabaseDriver"
            url = "jdbc:tc:postgresql:17.5-alpine:///test-db"
        }
        generator {
            database {
                name = "org.dema.jooq.liquibase.LiquibasePostgresTcDatabase"
                inputSchema = "public"
                includes = ".*"
                excludes = "databasechangelog|databasechangeloglock"
                properties {
                    property {
                        key = "liquibaseChangelogFile"
                        value = "${projectDir}/src/main/resources/liquibase/changelog-master.yml"
                    }
                }
            }
        }
    }
}
```

Run with `./gradlew jooqCodegen`. The first run pulls the Postgres image;
later runs reuse it.

`LiquibasePostgresTcDatabase` extends jOOQ's `PostgresDatabase` and applies the
changelog over the generator's own connection before jOOQ introspects metadata.

Footguns on both routes:

- `liquibaseChangelogFile` must be an **absolute** path. The library resolves
  relative `include` references from that file's directory, so a relative value
  silently fails to find included changelogs.
- Exclude `databasechangelog|databasechangeloglock` or Liquibase's bookkeeping
  tables end up in your generated API.

What the **convention plugin** sets for you, and the manual route does not — on
the manual route configure each one yourself or expect stock jOOQ behaviour:

- A `forcedType` mapping `timestamptz` to `java.time.LocalDateTime`. Stock jOOQ
  maps `timestamptz` to `OffsetDateTime`, so without that forced type you get a
  different generated type — and the offset back. The forced type is what makes
  `TimestampsRecordListener`, which writes `LocalDateTime`, line up with the
  generated records.
- `pojos`, `daos`, and `recordsImplementingRecordN` all off — you get `Record`s
  and `DSLContext` only. Do not go looking for a generated POJO to map to.
- A `target` under `build/generated/sources/jooq`, wired as its own `jooq`
  source set and kept out of VCS.

## 1. One repository per table on `AbstractRepository`

```kotlin
@Component
class CommentRepo : AbstractRepository<Comments, CommentsRecord>(COMMENTS) {
    fun commenterIdsOf(workItemId: UUID): List<UUID> =
        dsl.selectDistinct(COMMENTS.AUTHOR_ID)
            .from(COMMENTS)
            .where(COMMENTS.WORK_ITEM_ID.eq(workItemId))
            .fetch(COMMENTS.AUTHOR_ID)
}
```

The constructor takes the table and an optional `baseCondition` that defaults to
`noCondition()`, so a repository with no base filter passes the table alone.

The base class supplies a `protected dsl` and the inherited operations
`getOneBy`, `getAllBy`, `deleteBy`, `store`, `newRec`, `upsert`, and
`insertOnConflictDoNothing`, so each repository only adds what is specific to
its table. There is no `findById` and no `delete` — do not reach for them.

**Always wrap an inherited method in a method the repository declares itself**,
even a one-liner like `fun getOneById(id: UUID) = getOneBy { it.ID.eq(id) }`.
Those methods are compiled `final` in the jar and `dsl` is a `lateinit` field
injected into the target, so calling one from outside the class through a
proxied bean — a single `@Transactional` anywhere in the app is enough for
Spring to use a CGLIB subclass — runs against the un-autowired proxy and throws
`UninitializedPropertyAccessException: lateinit property dsl has not been
initialized`. That includes tests: give the test a repository method to call
rather than invoking `getOneBy`/`store` on the injected reference.

Return the generated `*Record` type. It already mirrors the table, so a parallel
DTO per table buys nothing and drifts. Map to a domain model at the service
boundary if the caller needs one, not inside the repository.

## 2. Bake soft-delete into `baseCondition`

```kotlin
@Component
class ProjectRepo : AbstractRepository<Projects, ProjectsRecord>(
    table = PROJECTS,
    baseCondition = PROJECTS.DELETED_AT.isNull.and(PROJECTS.ARCHIVED_AT.isNull),
) {
    fun contractorIdOf(projectId: UUID): UUID? =
        dsl.select(PROJECTS.CONTRACTOR_ID)
            .from(PROJECTS)
            .where(PROJECTS.ID.eq(projectId).and(baseCondition))
            .fetchOne(PROJECTS.CONTRACTOR_ID)

    fun getOneByIdIncludingDeleted(id: UUID): ProjectsRecord? =
        dsl.selectFrom(PROJECTS).where(PROJECTS.ID.eq(id)).fetchOne()
}
```

`getOneBy` and `getAllBy` route through the base class's
`selectFrom(table).where(baseCondition)`, so soft-deleted rows are invisible to
them by default.

**Nothing else applies it.** `deleteBy`, `upsert`, `insertOnConflictDoNothing`,
and every hand-written query in the repository build their own `where`, so they
must apply `.and(baseCondition)` themselves — that asymmetry is the usual
source of "why is this deleted row showing up". When you deliberately want the
filtered-out rows, put it in the method name (`getOneByIdIncludingDeleted`) so
the intent is visible at the call site.

## 3. Custom queries live as repository methods

Table-specific SQL belongs in the repository for that table, exposed as a named
method. Services call `commentRepo.commenterIdsOf(id)`; they never assemble a
query. Queries then sit next to the table they read, and service code stays
readable.

## 3a. No N+1: never issue a query — or any remote call — per row

A query inside a loop is banned, in repositories and in the services that call
them. jOOQ has no lazy loading and no session cache, so nothing rescues a
per-row query the way a Hibernate first-level cache sometimes masked one — every
iteration is a real round trip.

The same ban covers every other out-of-process call in a loop: HTTP/REST
requests, Kafka publishes, cache round trips, object-storage calls. The failure
mode is worse there than for SQL, because those calls are slower, and because a
loop that dies halfway leaves a partially-published, partially-written mess with
no transaction to roll back. Reach for the batch/bulk form of the API
(multi-record publish, a bulk endpoint, `mget`), or collect the work and issue
one call at the end.

The two shapes to watch for:

**Reads — a per-parent query for children.**

Wrong — one query for executions, then one more per execution:

```kotlin
val executions = executionRepo.findByTaskId(taskId)
val details = executions.map { execution ->
    val steps = stepRepo.findByExecutionId(execution.id)
    ...
}
```

Right — two queries total, grouped in Kotlin:

```kotlin
val executions = executionRepo.findByTaskId(taskId)
if (executions.isEmpty()) return emptyList()
val stepsByExecution = stepRepo
    .findByExecutionIdIn(executions.map { it.id })
    .groupBy { it.executionId }
val details = executions.map { execution ->
    val steps = stepsByExecution[execution.id].orEmpty()
    ...
}
```

Give the repository an `…In(ids: Collection<ID>)` method taking the whole id set
and returning the flat list; group by the foreign key at the call site. Two
round trips, constant in N. Guard the empty case — `IN ()` is a wasted query.

Prefer this two-query shape over a JOIN or `MULTISET` that reshapes children
into the parent row: it stays readable, avoids duplicating parent columns across
child rows, and does not depend on dialect-specific JSON aggregation.

**Writes — a statement per row.** `AbstractRepository.upsert` and
`insertOnConflictDoNothing` take a single record, so `records.forEach { upsert(it) }`
is N statements. Send one batch instead (`dsl.batch(queries).execute()`), or a
single multi-row insert. "It is only a handful of rows" is how this gets into a
hot path later.

**Verify by counting queries, not by asserting the result.** The N+1 version
returns exactly the same rows — a correctness test passes either way and proves
nothing. Count statements (a jOOQ `ExecuteListener` is the least intrusive way)
and assert the count is *constant* across two different N values, e.g. seed 3
parents and then 5 and expect the same number both times. A test that only
checks the count at one N cannot tell a constant from a coincidence.

**One legitimate exception:** per-item work that exists to get a per-item
*transaction boundary* — a reconciliation or batch job where each item is
handled in its own transaction and individually error-guarded, so one bad item
cannot roll back or abort the rest. Prefetching, or collapsing the sends into
one batch, would destroy exactly that isolation. When you rely on it, put the
isolation in the method name — `reconcileEachInOwnTransaction`, not
`reconcileAll` — and the reasoning in the commit message, or someone will
"optimise" it away. Not a comment: comments are banned, and a comment is the
first thing deleted by the person doing the optimising.

Note the exception is about *isolation*, not about convenience. "Each item needs
its own call because the API has no batch form" is not the exception — that is
an unbatched loop, and it still needs a bounded concurrency limit and a failure
policy that says what happens to items after the first error.

## 4. `DSLContext` never leaves the repository layer

```kotlin
@Service
class ProjectService(
    private val projectRepo: ProjectRepo,
) {
    fun contractorId(projectId: UUID): UUID? = projectRepo.contractorIdOf(projectId)
}
```

Services take repositories in the constructor, never a `DSLContext`. The check
is a grep: `DSLContext` should appear only inside repository classes. Anywhere
else means data access has leaked upward.

## 5. Audit timestamps come free

```yaml
dema:
  jooq:
    timestamps:
      enabled: true
      created-at-column: created_at
      updated-at-column: updated_at
```

`TimestampsRecordListener` fills the configured columns on every `store()`: the
created-at column only when it is still null, the updated-at column on every
write. So created-at survives updates and updated-at moves with each one. Do not
set either by hand in a record, a service, or a database trigger — you will get
two sources of truth that disagree.

## 6. Spring Data pagination

```kotlin
@Component
class UsersRepository : AbstractRepository<Users, UsersRecord>(table = USERS) {
    fun getPageBy(pageable: Pageable, condition: Condition): Page<UsersRecord> =
        JooqUtils.paginate(
            dsl,
            dsl.selectFrom(USERS).where(condition),
            pageable,
            USERS,
        )
}
```

`JooqUtils.paginate` turns a jOOQ query plus a Spring `Pageable` into a
`Page<R>`, so callers get the standard Spring Data contract without hand-rolled
count queries.

Convert filter objects to a jOOQ `Condition` through the registered
`ConversionService` rather than branching inside the service — see
[[mapstruct-converter-conventions]]:

```kotlin
@Service
class UserService(
    private val usersRepository: UsersRepository,
    private val conversionService: ConversionService,
) {
    @Transactional(readOnly = true)
    fun page(filter: UserFilter, pageable: Pageable): Page<User> =
        usersRepository
            .getPageBy(pageable, conversionService.convertNotNull(filter))
            .map { conversionService.convertNotNull(it) }
}
```

Mark read paths `@Transactional(readOnly = true)`. Prefer declarative
`@Transactional` over jOOQ's own `DSLContext.transaction { }` — mixing the two
hits known `SpringTransactionProvider` issues.

## 7. Prefer a scenario test; reach for a repository test only when nothing else can

**Do not write a test per repository method.** A repository is an implementation
detail, and a test that calls `commentRepo.commenterIdsOf(id)` and asserts on
rows is testing the mapping you just wrote, not the behaviour anyone depends on.
It also pins the repository's shape, so a later refactor breaks tests without
breaking the product.

Drive the real entry point instead — the HTTP request, the consumed message, the
scheduled job — and assert on what an observer sees: the response body, the rows
that resulted, the events published. That exercises the repository *and* the
service logic *and* the wiring, and it survives the repository being reshaped.
Whatever a scenario can reach, a scenario should cover.

A direct repository test earns its place only when a scenario genuinely cannot
reach the behaviour. Legitimate cases, all narrow:

- a query-count assertion pinning an N+1 fix (see §3a) where the counting
  harness would be unwieldy through a full scenario
- a write path with no read path in the product, so nothing observable exists
  to assert on — though that usually means the write is dead code, and deleting
  it beats testing it
- a branch reachable only from data an entry point cannot produce, such as rows
  left by an older schema version

When one of those applies, write it against real Postgres — never H2, never a
mocked repository, either of which hides the bug the test exists to catch:

```kotlin
internal class CommentRepoITCase : AbstractPostgresITCase() {

    @Autowired
    private lateinit var commentRepo: CommentRepo

    @Test
    fun `returns distinct comment authors of a work item`() {
        val workItem = TestWorkItemsRecord().storeRec()
        val author = UUID.randomUUID()
        repeat(2) { index ->
            TestCommentsRecord(workItemId = workItem.id, authorId = author, text = "c$index").storeRec()
        }
        val authors = commentRepo.commenterIdsOf(workItem.id)
        assertThat(authors, name = "distinct comment authors of $workItem").containsExactly(author)
    }
}
```

`AbstractPostgresITCase` starts one Postgres container from a companion-object
static initializer, registers it with `@ServiceConnection`, and issues
`TRUNCATE ... CASCADE` before each test, so tests cannot contaminate each other.

Build every fixture through a fake object per table (`TestWorkItemsRecord`,
`TestCommentsRecord`), never mixing them with raw `CommentsRecord()` calls in
the same test. A record built by its constructor is *detached* — it carries no
jOOQ `Configuration`, so `.store()` on it fails with `DetachedException`.
`storeRec()` is the project's test helper that attaches the record to the test
`DSLContext` and stores it, which is what keeps `DSLContext` out of the test.

The query runs against real Postgres, so a wrong column name or a bad cast fails
the test instead of production. Do not substitute H2 or a mocked repository —
either one hides exactly the bug this test exists to catch.

See [[kotlin-test-writing-rules]] for naming, `ITCase` layout, and fake-object
conventions.

## 8. Library and dialect caveats

Three edges of `jooq-starter`'s pagination and `RETURNING` support, each of
which produced a real bug or a real misunderstanding.

**`JooqUtils.paginate` reports a zero total for an empty window.**

The total rides on a `count() over ()` column carried by the returned rows,
and the `Page`-returning overload short-circuits with `if (result.isEmpty())
return Page.empty(pageRequest)`. A page past the end of the data therefore
reports `totalElements = 0` and `totalPages = 0` instead of the true count —
a caller cannot tell "no results at all" from "past the end of N results". A
separate `fetchCount` does not have this problem, because it counts
independently of the returned rows:

```kotlin
fun listOrders(pageable: Pageable): Page<OrderEntry> {
    val page = JooqUtils.paginate(dsl, dsl.selectFrom(ORDERS), sortFields, pageable, ORDERS)
    return if (page.isEmpty) {
        PageImpl(emptyList(), pageable, dsl.fetchCount(ORDERS).toLong())
    } else {
        page.map { it.toEntry() }
    }
}
```

The fallback count must carry the same predicate as the main query — here
there is none, so `fetchCount(ORDERS)` matches it. A filtered query needs the
same filter applied in both places, or the out-of-range total over-reports.

**Two `paginate` overloads resolve sorts differently.**

The overload taking `(dsl, select, pageable, table)` resolves `pageable.sort`
through a private helper that matches **physical column names**. A caller
sorting by a domain property whose column is spelled differently gets a
rejection instead of a sorted page. The overload taking an explicit
`SortField<?>[]` bypasses that resolution entirely. Whenever a
property-to-column map already exists for a repository, use the explicit
`SortField` overload and keep that map as the only translation path — do not
let both resolution paths exist for the same table.

**`returningResult` is emulated on SQLite, not native.**

On the Open Source edition, `nativeSupportReturning()` is false whenever
`fetchTriggerValuesAfterReturning()` is true, which is the OSS default. jOOQ
then emits an `insert …` followed by `select id from t where _rowid_ =
last_insert_rowid()` — no `RETURNING` clause reaches the query log. It is
still correct: jOOQ runs the follow-up `select` on the *same pinned
connection* as the `insert`, which is what makes the result independent of
any ambient transaction. A comment or error message asserting that a
`RETURNING` clause is on the wire will send the next reader looking for SQL
that is not there — describe the emulation, not the method name.
