# Kotlin/Spring Conventions Refresh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add 2025-2026 Kotlin/Spring/testing/jOOQ/Kafka convention updates to the shared `CLAUDE.md` and the `kotlin-test-writing-rules` skill, per the approved spec.

**Architecture:** Pure documentation edits. Additive bullets in existing CLAUDE.md sections, two rewordings, and one new section in the skill. No code, no build, no tests — verification is `grep`/`wc`/`git` and one fresh-session smoke check.

**Tech Stack:** Markdown. Target repo: `/home/l3r8y/code/oss/my-claude`. `CLAUDE.md` is symlinked to `~/.claude/CLAUDE.md`; the skill is symlinked to `~/.claude/skills/kotlin-test-writing-rules/`. Always edit the real files under the repo, never the symlinks.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-25-kotlin-spring-conventions-refresh-design.md`. Copy wording verbatim from it.
- `CLAUDE.md` must stay under ~200 lines (expected ~140 after edits).
- Match the existing terse bullet style in CLAUDE.md (bold lead-in where a category label helps, one line each). The skill section may be example-heavy — it loads on demand.
- Do NOT change `mapstruct-converter-conventions`.
- Commit messages: Conventional Commits, no ticket scope (matches this repo's own history, e.g. `docs: ...`). No AI attribution.
- Edit files at `/home/l3r8y/code/oss/my-claude/...`, not the `~/.claude` symlinks.

---

### Task 1: CLAUDE.md content edits

**Files:**
- Modify: `/home/l3r8y/code/oss/my-claude/CLAUDE.md`

**Interfaces:**
- Consumes: nothing.
- Produces: 6 section edits (4 append-bullet groups, 2 rewordings). Task 2 is independent of this task.

Each step is one `Edit` (exact old→new string). The anchor strings below are copied from the current file — match them exactly.

- [ ] **Step 1: Append 4 bullets to `## Kotlin idioms`**

Anchor on the last idiom bullet (Multi-input conversions) and append after it. Old string:

```
- **Multi-input conversions:** for a Spring `Converter` that needs more than one input, prefer a generic `Source<S, A>` pair type over a one-off `XxxEntitySource` data class per converter. See the `mapstruct-converter-conventions` skill for the full pattern (naming, shared `@MapperConfig`, `Source<S, A>`/`convertNotNull` examples).
```

New string (same line, then 4 new bullets):

```
- **Multi-input conversions:** for a Spring `Converter` that needs more than one input, prefer a generic `Source<S, A>` pair type over a one-off `XxxEntitySource` data class per converter. See the `mapstruct-converter-conventions` skill for the full pattern (naming, shared `@MapperConfig`, `Source<S, A>`/`convertNotNull` examples).
- **Control flow:** prefer guard conditions in `when` (`is Order.Paid if order.amount > 0 -> ...`, stable Kotlin 2.1+) over a nested `if` inside the branch.
- **Sealed hierarchies:** prefer `sealed interface` over `sealed class` unless the base genuinely needs shared state or behavior; always rely on an exhaustive `when` (no `else`) over a sealed type so a new subtype fails the build instead of silently falling through.
- **Domain errors:** `Result` is for generic/infrastructure failures, not domain modeling — model expected domain failures with a sealed class/interface, and reserve exceptions/`Result` for truly exceptional cases.
- **Domain primitives:** consider `@JvmInline value class UserId(val value: UUID)` for zero-cost type-safe wrappers; note it still boxes when used as a generic type argument, through an interface, or in a collection, so it is not unconditionally free.
```

- [ ] **Step 2: Append 3 bullets to `## Kotlin and Spring defaults`**

Old string (last bullet of that section):

```
- When applicable, consider metrics, tracing, timeouts, retries, idempotency, and backpressure.
```

New string:

```
- When applicable, consider metrics, tracing, timeouts, retries, idempotency, and backpressure.
- Prefer virtual threads (`spring.threads.virtual.enabled=true`, Spring Boot 3.2+ / Java 21+) over hand-rolled thread-pool tuning for blocking-I/O-heavy services; watch for `synchronized`-around-I/O and JDBC-driver/Kafka-client internals pinning the carrier thread — favor `ReentrantLock` over `synchronized` for I/O, and prefer a JDK 24+ (JEP 491) baseline where pinning matters.
- Prefer `@ConfigurationProperties` as an immutable `data class` with constructor binding, registered via `@ConfigurationPropertiesScan` rather than per-class `@EnableConfigurationProperties` (`@ConstructorBinding` is no longer needed at type level in Boot 3.x).
- Prefer `ProblemDetail` / RFC 7807 (`@ExceptionHandler` / `@RestControllerAdvice` returning `ProblemDetail`/`ErrorResponse`) as the default error-response shape over ad-hoc error models.
```

- [ ] **Step 3: Reword the GraphQL bullet in `## Architecture preferences`**

Old string:

```
- Prefer schema-first for GraphQL and other externally visible contracts when applicable.
```

New string:

```
- Prefer schema-first for GraphQL and other externally visible contracts when applicable — Spring for GraphQL (SDL-first) is the default; reach for a code-first library like graphql-kotlin only as a deliberate choice.
```

- [ ] **Step 4: Append 2 bullets to `## Testing defaults`**

Old string (last bullet of that section):

```
- Always give assertions a descriptive `name` argument with the actual/expected values, so failures are clear without re-running the test.
```

New string:

```
- Always give assertions a descriptive `name` argument with the actual/expected values, so failures are clear without re-running the test.
- Prefer `@ServiceConnection` (Spring Boot 3.1+) on the container field over manual `@DynamicPropertySource` wiring for Testcontainers.
- Prefer test slices (`@WebMvcTest` / `@DataJpaTest` / `@JooqTest`) for focused layer tests; reserve `@SpringBootTest` for true end-to-end / full-context scenarios.
```

- [ ] **Step 5: Append 2 bullets to `## Persistence and data access`**

Old string (last bullet of that section):

```
- Prefer explicit SQL or jOOQ-based solutions where they improve clarity and correctness.
```

New string:

```
- Prefer explicit SQL or jOOQ-based solutions where they improve clarity and correctness.
- Run jOOQ code generation against the migration-managed schema (Flyway/Liquibase) at build time; do not commit generated sources to VCS.
- Under Spring Boot, prefer declarative `@Transactional` over jOOQ's own `DSLContext.transaction { }` — mixing the two causes known `SpringTransactionProvider` integration issues.
```

- [ ] **Step 6: Reword idempotency bullet + append 2 bullets to `## Messaging and async flows`**

Old string (whole section body):

```
- For Kafka and other async integrations, consider idempotency, ordering, retries, deduplication, and observability.
- Prefer tests that validate eventual consistency and real integration behavior where practical.
- Be explicit about timeout handling and failure scenarios.
```

New string:

```
- For Kafka and other async integrations, consider idempotency, ordering, retries, deduplication, and observability. Kafka's idempotent-producer defaults (`enable.idempotence`, `acks=all`) have been on since Kafka 3.0 — verify they aren't overridden rather than assuming they must be enabled.
- Use the transactional outbox pattern (DB write + outbox row in one local transaction, relay/CDC publishes to Kafka) to keep a persistence write and its Kafka publish atomic.
- Prefer Spring Kafka's non-blocking retries (`@RetryableTopic` + `@DltHandler`) over blocking in-listener retry loops.
- Prefer tests that validate eventual consistency and real integration behavior where practical.
- Be explicit about timeout handling and failure scenarios.
```

- [ ] **Step 7: Verify all edits landed and size is sane**

Run:

```bash
cd /home/l3r8y/code/oss/my-claude
wc -l CLAUDE.md
grep -c 'ServiceConnection\|ProblemDetail\|value class\|RetryableTopic\|@ConfigurationPropertiesScan\|Spring for GraphQL\|since Kafka 3.0\|transactional outbox\|DSLContext.transaction\|guard conditions\|sealed interface\|virtual threads\|jOOQ code generation\|test slices' CLAUDE.md
```

Expected: `wc -l` under 200 (≈145). `grep -c` returns 14 (one line per accepted addition/reword). If any count is off, re-check the corresponding step.

- [ ] **Step 8: Commit**

```bash
cd /home/l3r8y/code/oss/my-claude
git add CLAUDE.md
git commit -m "docs: refresh kotlin/spring conventions in CLAUDE.md

Add current (2025-2026) guidance: when guard conditions, sealed
interfaces, Result-vs-domain-errors, value classes, virtual threads,
@ConfigurationPropertiesScan, ProblemDetail, @ServiceConnection, test
slices, jOOQ build-time codegen + @Transactional, Kafka outbox and
non-blocking retries. Reword the Kafka idempotence and GraphQL bullets
to match current defaults."
```

---

### Task 2: kotlin-test-writing-rules skill — Testing Infrastructure Notes

**Files:**
- Modify: `/home/l3r8y/code/oss/my-claude/skills/kotlin-test-writing-rules/SKILL.md`

**Interfaces:**
- Consumes: nothing. Independent of Task 1.
- Produces: one new `## Testing Infrastructure Notes` section inserted immediately before `## Quick Reference`. Must not touch the YAML frontmatter (`name`/`description`) — the skill's auto-trigger depends on it.

- [ ] **Step 1: Insert the new section before `## Quick Reference`**

Anchor on the divider + heading that currently precede the quick-reference table. Old string:

```
---

## Quick Reference
```

New string:

```
---

## Testing Infrastructure Notes

These apply when a test class talks to a real backing service (DB, Kafka) via Testcontainers, or when tuning test execution. They are not jtcop rules — they are operational conventions that keep integration tests fast and non-flaky.

### Testcontainers: singleton / reuse, not per-class

`@Testcontainers` + `@Container` stops and restarts the container **per test class**, even though Spring caches the application context across classes. That mismatch leaves the context pointing at a dead container and produces stale-connection failures. Start the container **once** from a shared base class (static initializer) instead, and register it with `@ServiceConnection`:

```kotlin
// src/test/kotlin/foo/it/AbstractPostgresITCase.kt
abstract class AbstractPostgresITCase {
    companion object {
        @JvmStatic
        @ServiceConnection
        val postgres = PostgreSQLContainer("postgres:16").withReuse(true).apply { start() }
    }
}
```

For fast local/CI runs, also set `testcontainers.reuse.enable=true` (in `~/.testcontainers.properties`) so the container survives between runs. `.withReuse(true)` alone is ignored unless that flag is on.

### JUnit 5 parallel execution (opt-in)

`junit.jupiter.execution.parallel.enabled=true` alone does nothing — it also needs a mode and a strategy:

```
junit.jupiter.execution.parallel.enabled = true
junit.jupiter.execution.parallel.mode.default = concurrent
junit.jupiter.execution.parallel.config.strategy = dynamic
```

Opt in per module, not globally. Parallel tests sharing a singleton Testcontainer or other mutable state will interfere — only enable it where tests are genuinely isolated.

### Konsist (optional structural enforcement)

To enforce the structural rules above (test classes contain only `@Test` methods, naming conventions, package layout) as a build check, prefer [Konsist](https://docs.konsist.lemonappdev.com/) — it reads the Kotlin AST, so it catches extension functions, top-level functions, and other Kotlin constructs that ArchUnit's bytecode approach misses.

---

## Quick Reference
```

- [ ] **Step 2: Verify the section landed and frontmatter is intact**

Run:

```bash
cd /home/l3r8y/code/oss/my-claude
grep -n 'Testing Infrastructure Notes\|testcontainers.reuse.enable\|Konsist\|parallel.mode.default' skills/kotlin-test-writing-rules/SKILL.md
head -4 skills/kotlin-test-writing-rules/SKILL.md
awk '/```/{n++} END{print n" fence markers (must be even)"}' skills/kotlin-test-writing-rules/SKILL.md
```

Expected: the grep shows 4 matches; `head -4` still shows the intact `---` / `name:` / `description:` / `---` frontmatter; fence-marker count is even (no broken code block).

- [ ] **Step 3: Fresh-session smoke check (skill still loads and auto-triggers)**

Run:

```bash
cd /tmp && claude -p "I'm writing a JUnit5 test class in Kotlin for OrderCalculator that talks to Postgres via Testcontainers. What conventions apply? Name the skill you used." --output-format text 2>&1
```

Expected: response names `kotlin-test-writing-rules` and mentions the singleton/`@ServiceConnection` Testcontainers convention (proves the new section is reachable and the frontmatter still triggers).

- [ ] **Step 4: Commit**

```bash
cd /home/l3r8y/code/oss/my-claude
git add skills/kotlin-test-writing-rules/SKILL.md
git commit -m "docs: add testing-infrastructure notes to kotlin-test-writing-rules skill

Cover Testcontainers singleton/@ServiceConnection reuse (vs per-class
restart), opt-in JUnit5 parallel execution config, and Konsist as an
optional AST-based structural enforcer."
```

---

### Task 3: Push

**Files:** none.

- [ ] **Step 1: Push both commits**

```bash
cd /home/l3r8y/code/oss/my-claude
git push
git log --oneline -4
git status -sb
```

Expected: push succeeds; `git status -sb` shows `## main...origin/main` with no ahead/behind. (Skip if the user wants to review before pushing.)

---

## Notes for the executor

- These edits are order-independent within Task 1 and between Task 1 and Task 2 — but keep them in separate commits as written for a clean history.
- If an anchor `old_string` doesn't match exactly (file drifted since this plan was written), re-Read the section and adjust the anchor, don't force it.
- No test suite exists in this repo; the `grep`/`wc`/fence-count checks and the fresh-session smoke check ARE the verification. Do not skip them.
