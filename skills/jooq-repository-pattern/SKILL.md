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

**Manual route** — the stock jOOQ Gradle plugin plus the Testcontainers-backed
`Database` implementation:

```kotlin
plugins {
    id("org.jooq.jooq-codegen-gradle")
}

dependencies {
    jooqGenerator("org.dema:jooq-liquibase-testcontainer:x.x.x")
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

Footguns:

- `liquibaseChangelogFile` must be an **absolute** path. The library resolves
  relative `include` references from that file's directory, so a relative value
  silently fails to find included changelogs.
- Exclude `databasechangelog|databasechangeloglock` or Liquibase's bookkeeping
  tables end up in your generated API.
- Under these defaults `timestamptz` maps to `java.time.LocalDateTime`.
- No POJOs, DAOs, or `RecordN` types are generated — you get `Record`s and
  `DSLContext` only. Do not go looking for a generated POJO to map to.
- Generated sources land in a dedicated `jooq` source set
  (`build/generated/sources/jooq`) and stay out of VCS.

## 1. One repository per table on `AbstractRepository`

```kotlin
@Component
class CommentRepo : AbstractRepository<Comments, CommentsRecord>(
    table = COMMENTS,
    baseCondition = noCondition(),
) {
    fun commenterIdsOf(workItemId: UUID): List<UUID> =
        dsl.selectDistinct(COMMENTS.AUTHOR_ID)
            .from(COMMENTS)
            .where(COMMENTS.WORK_ITEM_ID.eq(workItemId))
            .fetch(COMMENTS.AUTHOR_ID)
}
```

The base class supplies a `protected dsl` and the common CRUD operations
(`findById`, `store`, `delete`), so each repository only adds what is specific
to its table.

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

Every query inherited from the base class picks the condition up automatically,
so soft-deleted rows are invisible by default.

**A hand-written query in the repository does not.** It builds its own `where`,
so it must apply `.and(baseCondition)` itself — that asymmetry is the usual
source of "why is this deleted row showing up". When you deliberately want the
filtered-out rows, put it in the method name (`getOneByIdIncludingDeleted`) so
the intent is visible at the call site.

## 3. Custom queries live as repository methods

Table-specific SQL belongs in the repository for that table, exposed as a named
method. Services call `commentRepo.commenterIdsOf(id)`; they never assemble a
query. Queries then sit next to the table they read, and service code stays
readable.

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

`TimestampsRecordListener` populates the configured columns on every `store()`,
on both insert and update. Do not set them by hand in a record, a service, or a
database trigger — you will get two sources of truth that disagree.

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

## 7. Test repositories against real Postgres

```kotlin
internal class CommentRepoITCase : AbstractIntegrationTest() {

    @Autowired
    private lateinit var commentRepo: CommentRepo

    @Test
    fun `returns distinct comment authors of a work item`() {
        val workItem = TestWorkItemsRecord().storeRec()
        val author = UUID.randomUUID()
        repeat(2) { index ->
            CommentsRecord().apply {
                id = UUID.randomUUID()
                workItemId = workItem.id
                authorId = author
                text = "c$index"
            }.storeRec()
        }
        val authors = commentRepo.commenterIdsOf(workItem.id)
        assertThat(authors, name = "distinct comment authors of $workItem").containsExactly(author)
    }
}
```

`AbstractIntegrationTest` runs a Postgres container and issues
`TRUNCATE ... CASCADE` before each test, so tests cannot contaminate each other.
`storeRec()` persists a record without a test touching `DSLContext` directly.

The query runs against real Postgres, so a wrong column name or a bad cast fails
the test instead of production. Do not substitute H2 or a mocked repository —
either one hides exactly the bug this test exists to catch.

See [[kotlin-test-writing-rules]] for naming, `ITCase` layout, and fake-object
conventions.
