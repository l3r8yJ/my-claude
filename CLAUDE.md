# Shared engineering guidance for Kotlin projects

This repo also ships four on-demand skills — `kotlin-test-writing-rules`, `mapstruct-converter-conventions`, `jooq-repository-pattern`, and `nextbi-analytics-contracts` — for guidance too narrow or example-heavy to keep loaded every session. Claude applies them automatically when relevant.

IMPORTANT:

- When applicable, prefer using intellij-index MCP tools for code navigation, symbol lookup, usage search, and safe refactoring.
- Prefer minimal, targeted changes over broad rewrites.
- Preserve the existing project style unless there is a clear reason to change it.
- Do not mention Claude, Anthropic, or any AI tool in commit messages, PR descriptions, or code comments — no `Co-Authored-By: Claude`, no "Generated with Claude Code", no similar attribution.

## Commit message format

- Follow [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/#specification) for every commit message.
- Use the ticket name as the scope, e.g. `feat(PROJ-123): add retry to payment client`.
- If the ticket name isn't already known from context, ask for it before committing — do not guess or omit the scope.

## General engineering defaults

- Prefer simple, readable, and maintainable Kotlin code.
- Follow DRY, but do not introduce abstractions too early.
- Prefer the simplest solution that keeps production reliability and performance reasonable.
- If there is a tradeoff between readability and performance, explain both approaches and prefer the simpler one unless the performance
  benefit is material.
- Prefer minimal invasive refactoring.
- Avoid changing public contracts, schemas, or APIs unless the task explicitly requires it.
- When making changes, consider backward compatibility, migration risks, and operational impact.

## Kotlin and Spring defaults

- Prefer Kotlin by default unless Java is explicitly requested.
- Prefer constructor injection.
- Avoid field injection.
- Prefer immutable models where practical.
- Prefer explicit code to clever abstractions.
- Prefer `runCatching` over `try/catch` only when it clearly improves readability and does not hide important control flow.
- Do not replace straightforward logic with chained scope functions if that makes the code harder to read.
- Add logging where it is operationally useful.
- When applicable, consider metrics, tracing, timeouts, retries, idempotency, and backpressure.
- Prefer virtual threads (`spring.threads.virtual.enabled=true`, Spring Boot 3.2+ / Java 21+) over hand-rolled thread-pool tuning for blocking-I/O-heavy services; watch for `synchronized`-around-I/O and JDBC-driver/Kafka-client internals pinning the carrier thread — favor `ReentrantLock` over `synchronized` for I/O, and prefer a JDK 24+ (JEP 491) baseline where pinning matters.
- Prefer `@ConfigurationProperties` as an immutable `data class` with constructor binding, registered via `@ConfigurationPropertiesScan` rather than per-class `@EnableConfigurationProperties` (`@ConstructorBinding` is no longer needed at type level in Boot 3.x).
- Prefer `ProblemDetail` / RFC 7807 (`@ExceptionHandler` / `@RestControllerAdvice` returning `ProblemDetail`/`ErrorResponse`) as the default error-response shape over ad-hoc error models.

## Kotlin idioms

- **Preconditions:** prefer `checkNotNull(x) { "message" }` / `requireNotNull(x) { "message" }` over `?: throw IllegalStateException(...)` / `?: throw IllegalArgumentException(...)`; prefer `check(condition) { "message" }` / `require(condition) { "message" }` over manual `if (!condition) throw ...`. Use `require*` for validating caller input (`IllegalArgumentException`) and `check*` for validating internal state (`IllegalStateException`). This generalizes beyond simple null/precondition checks: avoid a bare `throw SomeException(...)` statement anywhere a `check`/`require`/`error(...)` expression reads just as well (e.g. a timeout/deadline branch, a post-loop invariant) — reach for a raw `throw` only when a specific exception type must propagate for a downstream catch site that discriminates by type.
- **Collections:** prefer standard-library operators (`map`, `filter`, `associateBy`, `groupBy`, `partition`, `fold`, `sumOf`, `mapNotNull`, `flatMap`, `single`/`singleOrNull`) over manual mutable-accumulator loops. Prefer `buildList { }` / `buildMap { }` / `buildSet { }` over declaring a `mutableListOf()` and returning it. Reach for `asSequence()` only when chaining multiple operators over a genuinely large collection to avoid intermediate allocations — unnecessary for small/typical collections.
- **Null-safety:** prefer safe calls (`?.`), the Elvis operator (`?:`), and smart-casts over `!!`; reserve `!!` for cases where nullability is already proven impossible.
- **Data classes:** prefer `.copy()` over manually reconstructing an object field-by-field.
- **Multi-input conversions:** for a Spring `Converter` that needs more than one input, prefer a generic `Source<S, A>` pair type over a one-off `XxxEntitySource` data class per converter. See the `mapstruct-converter-conventions` skill for the full pattern (naming, shared `@MapperConfig`, `Source<S, A>`/`convertNotNull` examples).
- **Control flow:** prefer guard conditions in `when` (`is Order.Paid if order.amount > 0 -> ...`, preview in Kotlin 2.1, stable in 2.2+) over a nested `if` inside the branch.
- **Sealed hierarchies:** prefer `sealed interface` over `sealed class` unless the base genuinely needs shared state or behavior; always rely on an exhaustive `when` (no `else`) over a sealed type so a new subtype fails the build instead of silently falling through.
- **Domain errors:** `Result` is for generic/infrastructure failures, not domain modeling — model expected domain failures with a sealed class/interface, and reserve exceptions/`Result` for truly exceptional cases.
- **Domain primitives:** consider `@JvmInline value class UserId(val value: UUID)` for zero-cost type-safe wrappers; note it still boxes when used as a generic type argument, through an interface, or in a collection, so it is not unconditionally free.

## Function body style

- Function bodies must not contain blank lines or inline comments.
- All explanatory context — purpose, assumptions, edge cases, why — belongs in the KDoc/Javadoc block above the function signature, not inside the body.
- Keep KDoc/Javadoc terse and factual — state what the function does, its params, returns, and throws; no prose no one will read. If a line doesn't help a caller, cut it.

## Naming and API design

- Do not use the `DTO` suffix when generating or writing DTO classes.
- Prefer clear domain-specific names for request and response models.
- Keep naming consistent with existing bounded context terminology.
- Avoid redundant words in type names when the context already makes them obvious.

## Architecture preferences

- Prefer schema-first for GraphQL and other externally visible contracts when applicable — Spring for GraphQL (SDL-first) is the default; reach for a code-first library like graphql-kotlin only as a deliberate choice.
- Prefer database-first where persistence models can be generated from the database schema.
- Prefer contract-first thinking for external APIs and event schemas.
- Do not change a valid GraphQL schema unless the task explicitly requires it.
- Prefer contract-safe evolution over breaking changes.
- Prefer explicit mapping boundaries between transport, domain, and persistence models.

## Testing defaults

- Prefer JUnit 5.
- Prefer assertk (`assertThat`) for assertions, rather than JUnit 5 `Assertions` or Hamcrest. Group multiple assertions in a single test with assertk's `assertAll { }`.
- Prefer `spring-mockk` for mocking in Spring tests.
- For asynchronous assertions and eventual consistency checks, prefer `awaitility`.
- For integration tests, prefer Testcontainers.
- Use Testcontainers for PostgreSQL and Kafka when applicable.
- Do not use H2 as a substitute for PostgreSQL unless explicitly requested.
- Prefer realistic integration tests over overly mocked tests.
- Prefer integration tests for Spring Boot services when validating repository, messaging, and configuration flows, when practical.
- Prefer black-box tests: drive the service through its real entry point (HTTP/GraphQL request, consumed Kafka message, etc.) and assert on the observable outcome — the response, the resulting DB rows, published events, or app state change — rather than reaching into internals or asserting on mocks. Test behavior at the boundary, not implementation.
- Mock only genuinely external resources you don't control (third-party REST/HTTP responses, external services, clocks/randomness). Never mock what you can exercise for real — if the scenario can be set up by putting data in the DB (Testcontainers) and running the actual code path, do that instead of mocking. A mock that stands in for your own DB, repository, or business logic hides the bug you were trying to catch.
- Prefer fake-objects approach for shared test setup; see the `kotlin-test-writing-rules` skill for the full jtcop rule set (assertion style, naming, ITCase layout).
- Prefer JUnit 5 API like argument providers and custom extensions to provide data for tests.
- Always give assertions a descriptive `name` argument with the actual/expected values, so failures are clear without re-running the test.
- Prefer `@ServiceConnection` (Spring Boot 3.1+) on the container field over manual `@DynamicPropertySource` wiring for Testcontainers.
- Prefer test slices (`@WebMvcTest` / `@DataJpaTest` / `@JooqTest`) for focused layer tests; reserve `@SpringBootTest` for true end-to-end / full-context scenarios.

## Persistence and data access

- Prefer realistic database behavior in tests.
- Be careful with transaction boundaries, locking, isolation, and idempotency.
- When changing persistence logic, consider pagination, indexing, query cost, and migration safety.
- Prefer explicit SQL or jOOQ-based solutions where they improve clarity and correctness.
- Run jOOQ code generation against the migration-managed schema (Flyway/Liquibase) at build time; do not commit generated sources to VCS.
- Under Spring Boot, prefer declarative `@Transactional` over jOOQ's own `DSLContext.transaction { }` — mixing the two causes known `SpringTransactionProvider` integration issues.
- Prefer one repository per table over sharing a `DSLContext` across services; keep `DSLContext` inside the repository layer so table-specific SQL lives next to the table it queries and services depend on named repository methods.
- Bake soft-delete and other always-on filters into a repository-level base condition rather than repeating the predicate at each call site; expose an explicit escape hatch (e.g. `getOneByIdIncludingDeleted`) when a caller genuinely needs the filtered-out rows.

## Messaging and async flows

- For Kafka and other async integrations, consider idempotency, ordering, retries, deduplication, and observability. Kafka's idempotent-producer defaults (`enable.idempotence`, `acks=all`) have been on since Kafka 3.0 — verify they aren't overridden rather than assuming they must be enabled.
- Use the transactional outbox pattern (DB write + outbox row in one local transaction, relay/CDC publishes to Kafka) to keep a persistence write and its Kafka publish atomic.
- Prefer Spring Kafka's non-blocking retries (`@RetryableTopic` + `@DltHandler`) over blocking in-listener retry loops.
- Prefer tests that validate eventual consistency and real integration behavior where practical.
- Be explicit about timeout handling and failure scenarios.

## Refactoring and code navigation

- When searching usages, symbols, or performing safe refactoring in Kotlin/Java codebases, prefer intellij-index MCP tools over plain text
  search when available.
- Prefer targeted edits over rewriting whole files unnecessarily.
- When editing existing files, prefer minimal diffs and avoid unrelated cleanup.
- When modifying an existing file, change only the necessary parts and keep surrounding context small but sufficient.

## Response style for engineering tasks

Apply this to non-trivial or ambiguous tasks; skip the ceremony for small, obvious changes (a typo fix, a one-line config edit, a mechanical rename).

- Briefly restate the task and list explicit assumptions.
- Provide at least two approaches when there is a meaningful choice: a simple/reliable option and a more scalable/performance-oriented
  option.
- For each approach, explain why to use it, pros/cons, risks, and implementation cost.
- Give a recommendation and explain why.
- Finish with a concrete action plan and code/config examples.
