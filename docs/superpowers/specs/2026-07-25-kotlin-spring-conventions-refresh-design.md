# Kotlin/Spring conventions refresh — design

## Context

`CLAUDE.md` (the always-loaded global engineering guidance, currently ~116 lines) plus the on-demand `kotlin-test-writing-rules` skill were reviewed against current (2025-2026) Kotlin, Spring Boot, testing, jOOQ, and Kafka consensus via four parallel web-research agents. The research surfaced ~18 candidate improvements; the user triaged them item-by-item. This spec records the accepted set and their exact placement so implementation is mechanical.

Goal: add current-consensus guidance the file is missing and correct two outdated bullets, without pushing CLAUDE.md past the ~200-line always-loaded budget. No wholesale rewrite — additive bullets in existing sections, two rewordings, one new section in the skill.

Nothing here changes the `mapstruct-converter-conventions` skill.

## Accepted changes

### CLAUDE.md — `## Kotlin idioms` (append 4 bullets)

Match the existing terse bullet style (bold lead-in, one line).

- **Control flow:** prefer guard conditions in `when` (`is Order.Paid if order.amount > 0 -> ...`, stable Kotlin 2.1+) over a nested `if` inside the branch.
- **Sealed hierarchies:** prefer `sealed interface` over `sealed class` unless the base genuinely needs shared state/behavior; always rely on an exhaustive `when` (no `else`) over a sealed type so a new subtype fails the build instead of silently falling through.
- **Domain errors:** `Result` is for generic/infrastructure failures, not domain modeling — model expected domain failures with a sealed class/interface, reserve exceptions/`Result` for truly exceptional cases.
- **Domain primitives:** consider `@JvmInline value class UserId(val value: UUID)` for zero-cost type-safe wrappers; note it still boxes when used as a generic type argument, through an interface, or in a collection, so it is not unconditionally free.

### CLAUDE.md — `## Kotlin and Spring defaults` (append 3 bullets)

- Prefer virtual threads (`spring.threads.virtual.enabled=true`, Spring Boot 3.2+ / Java 21+) over hand-rolled thread-pool tuning for blocking-I/O-heavy services; watch for `synchronized`-around-I/O and JDBC-driver/Kafka-client internals pinning the carrier thread — favor `ReentrantLock` over `synchronized` for I/O, and prefer a JDK 24+ (JEP 491) baseline where pinning matters.
- Prefer `@ConfigurationProperties` as an immutable `data class` with constructor binding, registered via `@ConfigurationPropertiesScan` rather than per-class `@EnableConfigurationProperties` (`@ConstructorBinding` is no longer needed at type level in Boot 3.x).
- Prefer `ProblemDetail` / RFC 7807 (`@ExceptionHandler` / `@RestControllerAdvice` returning `ProblemDetail`/`ErrorResponse`) as the default error-response shape over ad-hoc error models.

### CLAUDE.md — `## Architecture preferences` (reword existing GraphQL bullet)

- **Before:** `Prefer schema-first for GraphQL and other externally visible contracts when applicable.`
- **After:** `Prefer schema-first for GraphQL and other externally visible contracts when applicable — Spring for GraphQL (SDL-first) is the default; reach for a code-first library like graphql-kotlin only as a deliberate choice.`

### CLAUDE.md — `## Testing defaults` (append 2 bullets)

- Prefer `@ServiceConnection` (Spring Boot 3.1+) on the container field over manual `@DynamicPropertySource` wiring for Testcontainers.
- Prefer test slices (`@WebMvcTest` / `@DataJpaTest` / `@JooqTest`) for focused layer tests; reserve `@SpringBootTest` for true end-to-end / full-context scenarios.

### CLAUDE.md — `## Persistence and data access` (append 2 bullets)

- Run jOOQ code generation against the migration-managed schema (Flyway/Liquibase) at build time; do not commit generated sources to VCS.
- Under Spring Boot, prefer declarative `@Transactional` over jOOQ's own `DSLContext.transaction { }` — mixing the two causes known `SpringTransactionProvider` integration issues.

### CLAUDE.md — `## Messaging and async flows` (reword existing bullet + append 2)

- **Reword** the existing `For Kafka and other async integrations, consider idempotency, ordering, retries, deduplication, and observability.` to append: `Kafka's idempotent-producer defaults (enable.idempotence, acks=all) have been on since Kafka 3.0 — verify they aren't overridden rather than assuming they must be enabled.`
- Append: Use the transactional outbox pattern (DB write + outbox row in one local transaction, relay/CDC publishes to Kafka) to keep a persistence write and its Kafka publish atomic.
- Append: Prefer Spring Kafka's non-blocking retries (`@RetryableTopic` + `@DltHandler`) over blocking in-listener retry loops.

### `kotlin-test-writing-rules` skill — new section before `## Quick Reference`

New `## Testing Infrastructure Notes` section (detail/example-heavy is fine here — loaded on demand):

- **Testcontainers singleton/reuse:** start containers from a static initializer / shared base class (or as Spring beans), not via `@Testcontainers`/`@Container` alone — that extension stops containers per test class even though the Spring context is cached across classes, causing stale-connection failures. Pair with `testcontainers.reuse.enable=true` + `.withReuse(true)` for fast local/CI runs. Include a short base-class code example.
- **JUnit 5 parallel execution (opt-in):** `junit.jupiter.execution.parallel.enabled=true` alone does nothing — also set `mode.default=concurrent` and a `config.strategy` (fixed/dynamic). Flag the shared-state / Testcontainers-singleton interaction risk; opt-in per module, not a global default.
- **Konsist (optional):** a Kotlin-native AST tool for enforcing the jtcop-style structural rules above (test-class-only-`@Test`, naming, package layout); catches Kotlin constructs (extension/top-level functions) that ArchUnit's bytecode approach misses.

## Rejected / not included

From the research set, deliberately **not** adopted:
- Micrometer Tracing / `Observation` API line (Spring/DI) — not selected in triage.
- Contract testing tool choice (Spring Cloud Contract vs Pact) — not selected in triage.
- Flyway-vs-Liquibase explicit pick as its own bullet — folded implicitly into the jOOQ-codegen bullet ("migration-managed schema (Flyway/Liquibase)"), no standalone recommendation.
- Avro/Protobuf + schema registry line (Kafka) — not selected in triage.
- Any change to `mapstruct-converter-conventions` skill — none proposed.

Confirmed still-current, no change: `!!`-avoidance, `buildList`/`buildMap`/`buildSet`, `checkNotNull`/`requireNotNull`, constructor injection / avoid field injection, spring-mockk (do not switch to bare MockK).

## Files to change

- `/home/l3r8y/code/oss/my-claude/CLAUDE.md` — the 6 section edits above (edit the real file, not the `~/.claude/CLAUDE.md` symlink).
- `/home/l3r8y/code/oss/my-claude/skills/kotlin-test-writing-rules/SKILL.md` — insert the new `## Testing Infrastructure Notes` section immediately before `## Quick Reference`.

## Verification

- `wc -l CLAUDE.md` stays under ~200 (expected ~140).
- `grep -n 'ServiceConnection\|ProblemDetail\|value class\|RetryableTopic\|@ConfigurationPropertiesScan\|Spring for GraphQL' CLAUDE.md` shows each new bullet present.
- `grep -n 'since Kafka 3.0' CLAUDE.md` confirms the idempotence reword landed (and the old bare wording is gone).
- `grep -n 'Testing Infrastructure Notes\|testcontainers.reuse.enable\|Konsist' skills/kotlin-test-writing-rules/SKILL.md` confirms the skill section.
- Fresh headless session (`claude -p`) still lists both skills and auto-triggers `kotlin-test-writing-rules` on a Kotlin-test prompt, as before — the new section must not break the frontmatter/description.
- Markdown sanity: no broken code fences in the skill after insertion.
