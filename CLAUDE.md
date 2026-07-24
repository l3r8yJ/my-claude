# Shared engineering guidance for Kotlin projects

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

## Kotlin idioms

- **Preconditions:** prefer `checkNotNull(x) { "message" }` / `requireNotNull(x) { "message" }` over `?: throw IllegalStateException(...)` / `?: throw IllegalArgumentException(...)`; prefer `check(condition) { "message" }` / `require(condition) { "message" }` over manual `if (!condition) throw ...`. Use `require*` for validating caller input (`IllegalArgumentException`) and `check*` for validating internal state (`IllegalStateException`). This generalizes beyond simple null/precondition checks: avoid a bare `throw SomeException(...)` statement anywhere a `check`/`require`/`error(...)` expression reads just as well (e.g. a timeout/deadline branch, a post-loop invariant) — reach for a raw `throw` only when a specific exception type must propagate for a downstream catch site that discriminates by type.
- **Collections:** prefer standard-library operators (`map`, `filter`, `associateBy`, `groupBy`, `partition`, `fold`, `sumOf`, `mapNotNull`, `flatMap`, `single`/`singleOrNull`) over manual mutable-accumulator loops. Prefer `buildList { }` / `buildMap { }` / `buildSet { }` over declaring a `mutableListOf()` and returning it. Reach for `asSequence()` only when chaining multiple operators over a genuinely large collection to avoid intermediate allocations — unnecessary for small/typical collections.
- **Null-safety:** prefer safe calls (`?.`), the Elvis operator (`?:`), and smart-casts over `!!`; reserve `!!` for cases where nullability is already proven impossible.
- **Data classes:** prefer `.copy()` over manually reconstructing an object field-by-field.
- **Multi-input conversions:** for a Spring `Converter` that needs more than one input, prefer a generic `Source<S, A>` pair type (`data class Source<S, A>(val source: S, val addition: A)`) built via an `infix fun <S, A> S.with(addition: A): Source<S, A>` over a one-off `XxxEntitySource` data class per converter. Pair it with a reified `ConversionService.convertNotNull<Source, Target>(source): Target` extension (`convert(source, Target::class.java) ?: error(...)`) instead of `convert(...)!!` or a hand-rolled `convertOrThrow`.

## Converter beans and ConversionService

- Prefer a MapStruct-generated `Converter<S, T>` over a hand-written Spring `Converter` bean or an ad-hoc mapping function. Define one shared `@MapperConfig` (e.g. `MapstructConfig`) with `componentModel = MappingConstants.ComponentModel.SPRING` and `unmappedTargetPolicy = ReportingPolicy.ERROR`, so every mapper shares the same settings and a build fails fast on an unmapped target field instead of silently leaving it null. Route shared named helper methods and nested-type delegation to the registered `ConversionService` through that same shared config's `uses = [...]`, rather than repeating `uses` on each mapper.
- Naming convention: `interface {Source}2{Target}Converter : Converter<Source, Target>` (or `abstract class` when a method body is required), annotated `@Mapper(config = SharedMapperConfig::class)`, with `override fun convert(...)`. Use `@Mapping(target = "...", source = "...")` for field renames instead of manual field-by-field assignment.
- Reserve fully hand-written `convert()` bodies for conversions MapStruct can't express (a single computed value, a non-bean-shaped source) — keep the `@Mapper(config = ...)` annotation on the `abstract class : Converter<S, T>` even then, so it still registers the same way as a generated mapper.
- Registration is automatic either way: Spring Boot's MVC auto-configuration detects every `Converter`/`GenericConverter`/`Formatter` bean (hand-written or MapStruct-generated) and registers it into the `mvcConversionService` `ConversionService` bean — do not hand-write a `GenericConversionService`/`FormatterRegistry` config class. Inject `ConversionService` (qualify with `@Qualifier("mvcConversionService")` only when more than one `ConversionService` bean exists in context) and call `convert`/`convertNotNull`.
- For a mapping that needs more than one input, keep the `Converter<S, T>` shape by wrapping the extra inputs in the `Source<S, A>` pair type above rather than widening `S` into a bespoke multi-field holder class.

## Function body style

- Function bodies must not contain blank lines or inline comments.
- All explanatory context — purpose, assumptions, edge cases, why — belongs in the KDoc/Javadoc block above the function signature, not inside the body.

## Naming and API design

- Do not use the `DTO` suffix when generating or writing DTO classes.
- Prefer clear domain-specific names for request and response models.
- Keep naming consistent with existing bounded context terminology.
- Avoid redundant words in type names when the context already makes them obvious.

## Architecture preferences

- Prefer schema-first for GraphQL and other externally visible contracts when applicable.
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
- Mock external boundaries, not core business logic, unless there is a strong reason.
- Prefer fake-objects approach
- Prefer JUnit api like argument providers, custom extensions to provide d© ata for tests.
- Always use assertion with messages with provided values, to have clear error messages when test failing

## Persistence and data access

- Prefer realistic database behavior in tests.
- Be careful with transaction boundaries, locking, isolation, and idempotency.
- When changing persistence logic, consider pagination, indexing, query cost, and migration safety.
- Prefer explicit SQL or jOOQ-based solutions where they improve clarity and correctness.

## Messaging and async flows

- For Kafka and other async integrations, consider idempotency, ordering, retries, deduplication, and observability.
- Prefer tests that validate eventual consistency and real integration behavior where practical.
- Be explicit about timeout handling and failure scenarios.

## Refactoring and code navigation

- When searching usages, symbols, or performing safe refactoring in Kotlin/Java codebases, prefer intellij-index MCP tools over plain text
  search when available.
- Prefer targeted edits over rewriting whole files unnecessarily.
- When editing existing files, prefer minimal diffs and avoid unrelated cleanup.
- When modifying an existing file, change only the necessary parts and keep surrounding context small but sufficient.

## Response style for engineering tasks

- Briefly restate the task and list explicit assumptions.
- Provide at least two approaches when there is a meaningful choice: a simple/reliable option and a more scalable/performance-oriented
  option.
- For each approach, explain why to use it, pros/cons, risks, and implementation cost.
- Give a recommendation and explain why.
- Finish with a concrete action plan and code/config examples.

# Kotlin Test Writing Rules

---

## 1. Only Test Methods in Test Classes

A test class must contain **only** functions annotated with `@Test`. No helper functions, no utility logic, no companion objects with shared
state, no `private` helper methods.

```kotlin
// Wrong
class PhrasesTest {
    @Test
    fun countsGreetings() {
        ...
    }

    fun helperMethod() {
        ...
    }  // ← NOT allowed
}

// Correct
class PhrasesTest {
    @Test
    fun countsGreetings() {
        ...
    }

    @Test
    fun countsQuestions() {
        ...
    }
}
```

> jtcop rule: `RuleOnlyTestMethods`

---

## 2. Every Test Must Have at Least One Assertion

Each `@Test` function must contain at least one assertion. Use **assertk** (`assertThat`) — not manual `if` checks, `check()`,
or `require()`.

```kotlin
// Wrong — no assertion framework
@Test
fun checks() {
    if (actual != expected) {
        throw AssertionError("failed")
    }
}

// Correct — uses assertk assertThat
@Test
fun checks() {
    assertThat(actual, name = "value generated by seed 127").isEqualTo(-1190496726)
}
```

> jtcop rule: `RuleAssertionMessage` (no-assertions)

---

## 3. Every Assertion Must Have a Descriptive Name

Every assertion must include a meaningful `name` explaining what is being verified. A missing name makes failures hard to diagnose.

```kotlin
// Wrong — no name
assertThat(actual).isEqualTo(expected)

// Correct — name explains what is expected
assertThat(actual, name = "value generated by seed $seed").isEqualTo(expected)
```

Kotlin string templates (`"seed $seed equals $expected"`) are preferred over `String.format()` for readability.

When a test has more than one assertion, wrap them in assertk's `assertAll { }` so every failure is reported together instead of
stopping at the first:

```kotlin
@Test
fun `computes both fields`() {
    assertAll {
        assertThat(result.total, name = "total").isEqualTo(42)
        assertThat(result.label, name = "label").isEqualTo("done")
    }
}
```

> jtcop rule: `RuleAssertionMessage` (empty-assertion-message)

---

## 4. Test Function Names Use Present Tense

Test function names must be written as present-tense verb phrases without a subject. The name describes what the system *does*, not what
*was done* or *should be done*.

In Kotlin, backtick names with spaces are allowed and can improve readability — use them when the name would otherwise be awkward.

```kotlin
// Wrong
fun createUser() {
    ...
}       // imperative
fun userIsCreated() {
    ...
}    // passive voice
fun userWasRemoved() {
    ...
}   // past tense

// Correct — camelCase
fun createsUser() {
    ...
}
fun createsUserWithoutName() {
    ...
}
fun removesUser() {
    ...
}

// Also correct — backtick names (Kotlin-idiomatic for tests)
fun `creates user without name`() {
    ...
}
fun `throws on null input`() {
    ...
}
fun `returns empty list when no data`() {
    ...
}
```

Pattern: **verb + object + [conditions]** — e.g., `countsSimpleGreetings`, `throwsOnNullInput`, `returnsEmptyListWhenNoData`.

> jtcop rule: `PresentTense`

---

## 5. One Test Class Per Live Class

Name each test class after the live class it covers, with a `Test` suffix. This is a navigation contract: "bugs I catch live in the class
whose name matches mine minus `Test`."

```
Phrases.kt      → PhrasesTest.kt
Greetings.kt    → GreetingsTest.kt
```

Do not split one live class across multiple test classes. Do not put tests for multiple live classes in a single test class.

---

## 6. Test Class Size Is Not a Problem

A test class is a container for test scripts, not a design unit. Having 5000 lines in a test class is acceptable. Do not refactor test
classes for size alone.

---

## 7. Shared Prerequisites: Use Fake Objects (Preferred)

Shared test setup should live in **fake/factory objects** placed in `src/main/kotlin`. This makes them reusable across projects,
independently testable, and free from coupling to any test framework.

```kotlin
// src/main/kotlin/foo/FactoryOfPhrases.kt
class FactoryOfPhrases {
    fun aboutLondon(): Phrases = Phrases().apply {
        add("Hello, world!")
        add("London is a capital of Great Britain")
    }
}

// src/test/kotlin/foo/PhrasesTest.kt
class PhrasesTest {
    @Test
    fun `counts simple greetings`() {
        assertThat(
            FactoryOfPhrases().aboutLondon().greetings().count(),
            name = "total count of greetings",
        ).isEqualTo(1)
    }
}
```

The factory ships with live code and has its own test: `FactoryOfPhrasesTest.kt`.

### If fake objects are not feasible: use a `support/` sub-package

Place shared test-only helpers in a sub-package that has no counterpart in `src/main/kotlin`:

```
src/test/kotlin/foo/support/FooUtils.kt   ← test-only, not a live class
```

Prefer top-level functions or objects over utility classes — Kotlin does not need `FooUtils` static wrappers.

Never put non-test helpers directly in the test root package.

---

## 8. Integration Tests

Use the `ITCase` suffix for integration tests (Maven/Gradle convention).

- If the integration test targets a specific class: place it alongside unit tests as `GreetingsITCase.kt`.
- If it spans multiple classes with no single owner: place it in an `it/` sub-package with a descriptive arbitrary name.

The `it/` package must not exist in `src/main/kotlin`.

---

## Directory Layout

```
src/
  main/
    kotlin/
      foo/
        FactoryOfPhrases.kt     ← fake/factory object (live, reusable, testable)
        Phrases.kt
        Greetings.kt
  test/
    kotlin/
      foo/
        it/
          SimpleGuessingITCase.kt   ← integration test for no single class
        support/
          FooUtils.kt               ← shared helpers (only if not using fakes)
        FactoryOfPhrasesTest.kt
        PhrasesTest.kt
        GreetingsTest.kt
        GreetingsITCase.kt          ← integration test for Greetings.kt
```

---

## Kotlin-Specific Notes

- **Backtick test names** — use `` fun `creates user without name`() `` freely; they produce clearer test output than camelCase
- **`apply` / `also` for setup** — use scope functions in factory methods instead of verbose builder chains
- **No `companion object` in test classes** — static helpers belong in the fake object in `src/main/kotlin`, not in a companion
- **`object` fakes** — for stateless factories, a Kotlin `object` is cleaner than a class:
  `object FakeOfPhrases { fun aboutLondon() = ... }`
- **assertk grouping** — wrap multiple assertions in one test with `assertAll { }` (from `assertk`, not JUnit 5) so all failures surface together
- **Kotest alternative** — if using Kotest instead of JUnit 5, the same rules apply: one spec class per live class, descriptive test names
  in present tense, every test must assert

---

## Quick Reference

| Rule                           | Requirement                                                  |
|--------------------------------|--------------------------------------------------------------|
| Only test methods              | `@Test` only — no helpers, no companion objects              |
| At least one assertion         | Every `@Test` must assert something (assertk `assertThat`)   |
| Assertion has a name           | Every `assertThat` needs a descriptive `name`                |
| Present tense names            | `createsUser()` or `` `creates user` `` — not `createUser()` |
| One test class per live class  | `FooTest` tests `Foo`, nothing else                          |
| No size limit on test classes  | 5000 lines is fine                                           |
| Fake objects for shared setup  | Live in `src/main/kotlin`, ship with production code         |
| Integration tests use `ITCase` | Cross-class ones go in `it/` sub-package                     |
