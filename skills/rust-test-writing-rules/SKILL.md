---
name: rust-test-writing-rules
description: Use when writing or reviewing Rust tests - unit vs integration placement, naming, assertions, fixtures, async tests, testcontainers, controlling time, property tests, snapshot tests, and what not to mock.
---

# Rust Test Writing Rules

## Where a test goes, and what that says

| Location | Sees | Use for |
| --- | --- | --- |
| `#[cfg(test)] mod tests` in the source file | private items | a parser, a state transition, a tricky pure function |
| `tests/*.rs` | only the crate's public API | anything a caller can reach |
| `benches/`, `examples/` | public API | not tests; still must compile in CI |
| doctests in `///` | public API | the example a user copies |

The split is a design signal, not filing. If a behavior is worth testing but
unreachable from `tests/`, either it should be public or the private helper it
lives in is being tested instead of the behavior. Prefer `tests/` — a test
that can only be written against internals pins the internals, and the next
refactor breaks the test without breaking the product.

Each file in `tests/` compiles as its own crate. Shared setup lives in
`tests/common/mod.rs` (the `mod.rs` form, so cargo does not treat it as a test
target of its own), imported with `mod common;`.

## Naming

The name is a sentence about behavior, in the present tense, with no `test_`
prefix — the `#[test]` attribute already said that.

```rust
#[test]
fn rejects_an_expired_token() { ... }

#[test]
fn returns_none_when_the_cart_is_empty() { ... }

#[test]
fn retries_three_times_before_giving_up() { ... }
```

Not `test_validate`, not `validate_works`, not `test_case_2`. A failing test
prints its name and nothing else useful; the name is the bug report.

Name what is being asserted, not what is being called. `parses_iso8601` is a
method name in disguise; `accepts_a_timezone_offset_without_a_colon` is a
behavior.

## Structure

Arrange, act, assert — in that order, with the act as a single line. Since
function bodies carry no comments and no blank lines, the shape has to come
from the code:

```rust
#[test]
fn refunds_the_full_amount_when_the_order_is_unshipped() {
    let order = Order::fake().unshipped().with_total(Money::eur(50_00));
    let refund = order.cancel().expect("an unshipped order can always be cancelled");
    assert_eq!(refund.amount(), Money::eur(50_00), "full total is refunded");
}
```

One behavior per test. Two acts in one body means the second assertion never
runs when the first fails, and the name can only describe one of them.

## Assertions

- `assert_eq!(actual, expected, "what this proves")` — the message is not
  optional. A failure that prints `left: 3, right: 4` and nothing else costs a
  re-read of the test to learn what 3 and 4 were.
- Argument order is `(actual, expected)`. Consistency matters more than which,
  but the whole repo picks one.
- `assert!(cond, "…")` for booleans; prefer `assert_eq!` whenever there are two
  values, because it prints both.
- `assert_matches!` (or a `matches!` + `assert!`) for enums — it names the
  variant instead of requiring `PartialEq` on a whole error type.
- For a large or nested value, prefer a snapshot (`insta`) over a wall of
  field-by-field assertions. `insta::assert_debug_snapshot!(response)` fails
  with a readable diff and updates with `cargo insta review`.
- `pretty_assertions::assert_eq!` when comparing structs — the default diff on
  a large `Debug` output is unreadable.
- Assert on the *observable outcome*, not on how it was reached. Asserting a
  mock was called twice tests the implementation; asserting the resulting rows
  or the response body tests the product.

## Fixtures: fakes, not builders-of-builders

Shared setup is a fake object with sensible defaults and a chainable override
per field that a test actually varies:

```rust
impl Order {
    pub fn fake() -> Self {
        Self { id: OrderId::new(), state: State::Paid, total: Money::eur(10_00), lines: vec![OrderLine::fake()] }
    }
    pub fn unshipped(mut self) -> Self { self.state = State::Paid; self }
    pub fn with_total(mut self, total: Money) -> Self { self.total = total; self }
}
```

Put `fake()` behind `#[cfg(any(test, feature = "test-util"))]` so it is
available to `tests/` and to downstream crates that need it, without shipping
in a release build.

A test names only the fields its behavior depends on. If a test sets six
fields and asserts on one, five of them are noise that the next reader has to
prove irrelevant.

## Table-driven cases

Prefer `rstest` over a hand-rolled loop over a `vec!` of cases — a loop
reports one failure for the whole table and stops at the first, while `rstest`
generates a named test per case:

```rust
#[rstest]
#[case::no_colon("+0300", 3 * 3600)]
#[case::with_colon("+03:00", 3 * 3600)]
#[case::zulu("Z", 0)]
fn parses_timezone_offsets(#[case] input: &str, #[case] expected_secs: i32) {
    assert_eq!(parse_offset(input).unwrap().as_secs(), expected_secs, "offset for {input}");
}
```

`rstest` also supplies fixtures by argument name and supports `#[future]` for
async cases.

## Property tests

Reach for `proptest` where a hand-picked table cannot cover the space: a
parser, a serializer, an ordering, an arithmetic invariant. The value is in
round-trips and invariants, not in re-deriving the implementation:

```rust
proptest! {
    #[test]
    fn a_serialized_order_round_trips(order in any::<Order>()) {
        let bytes = serde_json::to_vec(&order).unwrap();
        prop_assert_eq!(serde_json::from_slice::<Order>(&bytes).unwrap(), order);
    }
}
```

Commit the `proptest-regressions/` files — that is how a shrunk
counter-example becomes a permanent regression test.

## Async tests

```rust
#[tokio::test]
async fn publishes_an_event_when_the_order_ships() { ... }
```

- `#[tokio::test(flavor = "multi_thread")]` only when the test genuinely needs
  parallelism; the default current-thread runtime is faster and more
  deterministic.
- **Never `sleep` to wait for something.** Under CI load the sleep is too
  short; on a fast machine it is wasted wall clock; and it states nothing
  about the condition. Use a `oneshot`/`Notify`/`watch` channel the code under
  test signals, or poll the condition with a deadline.
- **Control time instead of passing it.** `tokio::time::pause()` makes the
  runtime auto-advance when idle, so a test of a 30-second timeout finishes
  instantly and deterministically:

```rust
#[tokio::test(start_paused = true)]
async fn gives_up_after_the_timeout() {
    let call = tokio::spawn(fetch_with_timeout(Duration::from_secs(30)));
    tokio::time::advance(Duration::from_secs(31)).await;
    assert!(matches!(call.await.unwrap(), Err(FetchError::TimedOut)), "times out at 30s");
}
```

- Inject a clock (a `Clock` trait, or `tokio::time::Instant` which `pause()`
  controls) rather than calling `SystemTime::now()` inside the logic. A test
  that fails on 31 December is a test that encoded a real bug nobody found.

## Integration tests with real dependencies

Use `testcontainers` for PostgreSQL, Kafka, Redis, S3 — the real engine, not a
substitute. SQLite is not PostgreSQL: it differs on types, on concurrency, on
`ON CONFLICT`, on everything a migration will eventually depend on.

```rust
async fn postgres() -> (ContainerAsync<Postgres>, PgPool) {
    let container = Postgres::default().start().await.expect("postgres starts");
    let url = format!("postgres://postgres:postgres@127.0.0.1:{}/postgres",
        container.get_host_port_ipv4(5432).await.expect("port is mapped"));
    let pool = PgPool::connect(&url).await.expect("pool connects");
    sqlx::migrate!().run(&pool).await.expect("migrations apply");
    (container, pool)
}
```

Hold the container handle for the whole test — dropping it stops the
container, and a mysteriously closed connection is the symptom. Start one
container per test binary (a `OnceCell`) and isolate tests by schema or by
transaction rollback, rather than paying container startup per test.

Drive the test through the real entry point. For an axum service that means
the router, not the handler function:

```rust
let response = app().oneshot(Request::builder().uri("/orders/7").body(Body::empty()).unwrap()).await.unwrap();
```

That exercises routing, extractors, middleware, serialization and the handler
at once — the four places a bug actually lives.

## What to mock, and what never to

Mock only what you do not control and cannot run: third-party HTTP
(`wiremock`), a payment provider, the system clock, randomness.

Never mock your own database, your own repository, or your own business logic.
A test where the repository is a mock returning the row the test wrote proves
that the mock works. The bug is in the SQL, and the mock is exactly what hides
it.

```rust
let provider = MockServer::start().await;
Mock::given(method("POST")).and(path("/charges"))
    .respond_with(ResponseTemplate::new(502))
    .mount(&provider).await;
```

Point the config at `provider.uri()` and assert the service degrades the way
it promises. Test the failure responses, not just the happy one — the 500, the
timeout, the malformed body. Those are the paths that page someone.

## One workflow beats five steps

Prefer a single test that walks a whole lifecycle — create, pay, ship, refund
— over five tests that each poke one transition. State-machine bugs live
*between* the steps: a stage that never advances, a status that is written but
never read. Per-step tests are blind to exactly those.

Keep the per-step tests for the branches the workflow cannot reach: an error
path, a rejected input, a race.

## Running

```
cargo test --all-features
cargo nextest run              # parallel, better output, per-test timeouts
cargo test --doc               # nextest does not run doctests
```

`cargo nextest` runs each test in its own process, so a test that leaks global
state or aborts no longer takes the binary with it. It does not run doctests —
run those separately in CI.

## Reviewing a Rust test

- Does the name state a behavior, or a method name?
- Is there more than one act in the body?
- Does every assertion carry a message with the values in it?
- Is any real dependency mocked that a container could run?
- Is there a `sleep`, or a `SystemTime::now()` in the code under test?
- Does the test reach into a private item that `tests/` could not see?
- Are the failure paths tested, or only the happy one?
- Is a container handle dropped before the test ends?
