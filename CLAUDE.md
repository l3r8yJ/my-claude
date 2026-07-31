# Shared engineering guidance for Kotlin projects

This repo also ships thirteen on-demand skills — `kotlin-test-writing-rules`, `mapstruct-converter-conventions`, `jooq-repository-pattern`, `migrating-jpa-to-jooq-starter`, `nextbi-analytics-contracts`, `verifying-library-behavior`, `writing-halt-gates-into-plans`, `reviewing-across-task-seams`, `feature-development`, `environment-scan`, `driving-gitlab-ci-with-glab`, `porting-a-fix-across-diverged-branches`, and `reviewing-a-blocking-wait` — for guidance too narrow or example-heavy to keep loaded every session. Claude applies them automatically when relevant.

IMPORTANT:

- Prefer minimal, targeted changes over broad rewrites.
- Preserve the existing project style unless there is a clear reason to change it.
- Do not mention Claude, Anthropic, or any AI tool in commit messages, PR descriptions, or code comments — no `Co-Authored-By: Claude`, no "Generated with Claude Code", no similar attribution.
- **Never commit brainstorming artifacts.** Design docs, specs, implementation plans, task briefs, research notes and any other working output of a brainstorming or planning workflow — including everything a skill writes under `docs/superpowers/` — stays local and untracked. Write it to the working tree, use it, but keep it out of every commit, branch and PR. If a repo already tracks such files, untrack them (`git rm -r --cached <dir>`) and add the path to `.gitignore`. This applies even when a workflow's own instructions say to commit the document — that instruction is overridden here. Anything from those documents that the team genuinely needs belongs in the PR description or the ticket, written for a reader who has not seen the plan.

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
- **Unused code is banned — delete it, do not keep it.** A method, class, field, parameter, dependency, config key, feature flag, or migration helper with no remaining caller gets removed in the same change that orphans it. Never leave something behind because "it might be useful later" or because it looks harmless: dead code still gets read, refactored, reviewed and kept compiling, and it lies about what the system does. Version control is the archive — anything deleted is one `git log -S` away, so nothing is lost by removing it.
- Delete the code and its tests **together**. A test is not a caller: a method whose only remaining caller is its own test is dead, and the test is what disguises it. If deleting a test would orphan production code, that is the signal to delete both, not to keep the test.
- Before deleting, prove the code is unused rather than assuming it — search the whole repository, not just the module: other source sets, tests, resources, config files, DI wiring, reflective lookups, serialized names, database or API contracts. Anything reachable by name rather than by a compiler-visible call is exactly what a narrow search misses. If it is part of a published API or contract another team consumes, deprecate first instead of deleting.
- **No out-of-process calls inside a loop.** Database queries, HTTP/REST requests, Kafka publishes, cache and object-storage round trips — none of them belong in a `for`/`forEach`/`map` body, in any layer. Use the batch or bulk form (an `IN (…)` query, a multi-record publish, a bulk endpoint) and group results in memory, or collect the work and issue one call at the end. Two round trips that stay constant beat N that grow with the data. Beyond latency, a loop of remote calls that fails halfway leaves partially-applied state with no transaction to roll back. The sole exception is per-item work that exists to give each item its own transaction boundary and error guard, as in a reconciliation job — it is indistinguishable from the bug on sight, so name the method for the isolation it buys (`reconcileEachInOwnTransaction`, not `reconcileAll`) and spell the reasoning out in the commit message. "The API has no batch form" is not that exception: it is still an unbatched loop, and it needs a bounded concurrency limit and an explicit policy for what happens to the remaining items after the first failure.
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

## Comments are banned

- **Write no comments.** Not inline `//`, not block `/* */`, not KDoc or Javadoc, not TODO/FIXME markers, not section banners (`// ─── setup ───`), not commented-out code. This holds in production sources, tests, and build scripts (`build.gradle.kts`, `settings.gradle.kts`) alike. Function bodies additionally must not contain blank lines.
- A comment is a bug report against the code it sits above. If a line needs explaining, the explaining goes into the code: rename the variable, extract a named function, replace the magic number with a named constant, put the sentence into the `require`/`check`/`error` message where a reader hits it at the moment it matters. Every one of those survives refactoring; a comment silently rots into a lie the moment the code under it changes, and nothing fails when it does.
- Things people reach for a comment to record, and where they actually go:
  - *Why this workaround exists, what broke, what was tried* — the commit message. That is what `git log`, `git blame` and `git log -S` are for, and unlike a comment it is timestamped and attributable.
  - *A constraint a caller must respect* — enforce it. `require(...)` with a message beats a sentence asking politely.
  - *A known limitation or follow-up* — a ticket. A `// TODO` nobody is assigned to is not a plan, it is litter that outlives everyone who could have acted on it.
  - *What a test is checking* — the test name. Backticked Kotlin test names hold a full sentence.
  - *How the module fits together* — the MR description, or a `README.md` next to the code.
- Do not smuggle a comment back in as a docstring. "But this one is genuinely non-obvious" is the argument behind every comment ever written; the answer is still to make the code obvious. If that is truly impossible — a compiler bug, a third-party library behaving against its own documentation — the workaround is what needs justifying, so justify it in the commit that introduces it.
- Exceptions, and only these: machine-read annotations that happen to use comment syntax (`// language=SQL`, `// $COVERAGE-OFF$`, linter suppressions with no annotation form), licence headers a legal requirement mandates, and generated files. Nothing else.
- When editing existing code, delete the comments you encounter in the region you are already touching. Do not open a separate comment-removal pass across untouched files unless asked.

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
- **Never use `Thread.sleep` in a test.** A fixed sleep is either too short (flaky under CI load) or too long (slow suite), and it encodes no statement about what the test is waiting for. Use `awaitility` — `await().atMost(...).until { condition }` for a condition, `untilAsserted { ... }` when the wait is on assertions. This holds even when the sleep looks harmless: waiting for a clock to advance, for a debounce window, or for a background thread to start are all conditions worth naming. Poll on the thing that actually has to become true, and poll *before* the action when the value under test is already final afterwards — polling after a final value turns a real failure into a timeout instead of an immediate, readable mismatch. If nothing pollable exists, inject a controllable clock or a latch rather than sleeping.
- For integration tests, prefer Testcontainers.
- Use Testcontainers for PostgreSQL and Kafka when applicable.
- Do not use H2 as a substitute for PostgreSQL unless explicitly requested.
- Prefer realistic integration tests over overly mocked tests.
- Prefer integration tests for Spring Boot services when validating repository, messaging, and configuration flows, when practical.
- Prefer black-box tests: drive the service through its real entry point (HTTP/GraphQL request, consumed Kafka message, etc.) and assert on the observable outcome — the response, the resulting DB rows, published events, or app state change — rather than reaching into internals or asserting on mocks. Test behavior at the boundary, not implementation.
- **Do not test database queries directly through repositories when a scenario can reach them.** A per-repository-method test asserts the mapping you just wrote, pins an implementation detail so refactors break tests without breaking the product, and proves nothing about whether the feature works. Cover it with a full scenario through the real entry point instead — that exercises the query, the service logic and the wiring at once. Reach for a direct repository test only where a scenario genuinely cannot go: a query-count assertion pinning an N+1 fix, a branch reachable only from data no entry point can produce, or a write path with no read path in the product — and that last one usually means the write is dead code worth deleting rather than testing.
- Prefer one scenario that walks a whole workflow end to end over several tests that each poke one step of it. Lifecycle bugs — a state machine that stalls, a step that never advances — live between the steps, so per-step tests are blind to exactly the failures that matter most.
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
