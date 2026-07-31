---
name: rust-error-handling
description: Use when designing or reviewing error types in Rust - choosing thiserror vs anyhow, deciding what a public API returns, adding context to a `?`, handling partial failure, or when a signature returns `Box<dyn Error>`, `String`, or `Option` where a typed error belongs.
---

# Rust Error Handling

## The one rule that decides everything else

**A library returns errors its caller can match on. A binary erases them.**

Every other question here follows from which side of that line the code is on.
A `pub fn` in a crate someone else calls returns a typed error, because the
caller has to decide whether a failure is retryable, whether it maps to a 404
or a 500, whether it means the record is missing or the database is down. A
`main`, a request handler's outermost layer, or a one-off tool does not need
that — it needs a message and an exit code.

| | Library / `pub` API | Binary / top layer |
| --- | --- | --- |
| Crate | `thiserror` | `anyhow` (or `eyre`) |
| Return | `Result<T, MyError>` | `anyhow::Result<T>` |
| Caller does | `match err { NotFound => 404, ... }` | prints it, exits |

Mixing them is fine and normal: the same workspace has `thiserror` in its
domain crates and `anyhow` in its `main.rs`. What is not fine is `anyhow` in a
library signature — it throws away the discrimination the caller needed.

## Typed errors with `thiserror`

```rust
use thiserror::Error;

#[derive(Debug, Error)]
pub enum OrderError {
    #[error("order {0} not found")]
    NotFound(OrderId),
    #[error("order {id} is {actual}, expected {expected}")]
    WrongState { id: OrderId, actual: State, expected: State },
    #[error("payment provider rejected the charge: {reason}")]
    PaymentRejected { reason: String },
    #[error(transparent)]
    Database(#[from] sqlx::Error),
}
```

What earns its place in that enum:

- **One variant per thing the caller does differently.** If `NotFound` and
  `WrongState` both become a 400 and nothing else distinguishes them, they are
  one variant. Variants are not a taxonomy of what went wrong, they are the
  caller's branch list.
- **`#[from]` only for errors you genuinely wrap wholesale.** Two `#[from]`
  variants over the same source type will not compile, which is the type
  system telling you the conversion is ambiguous — add context at the call
  site instead.
- **`#[error(transparent)]`** when your variant adds nothing and should
  forward `Display` and `source()` untouched.
- **Messages are lowercase, no trailing period, no "error:" prefix.** They get
  composed into a chain — `failed to load order: order 7 not found: connection
  refused` — and each one is a clause, not a sentence.
- **Never put the whole struct in the message.** `#[error("invalid config:
  {0:?}")]` on a struct with a password field is how secrets reach logs.

### `#[non_exhaustive]` on a published enum

Adding a variant to a public error enum is a breaking change — a downstream
exhaustive `match` stops compiling. Mark a published crate's error enum
`#[non_exhaustive]` so callers must write a `_ =>` arm and you can add
variants in a patch release. Do **not** do this for a crate-internal error:
there, the broken `match` is exactly the compile error you want.

## `anyhow` at the top, with context

```rust
use anyhow::{Context, Result};

fn load_config(path: &Path) -> Result<Config> {
    let raw = fs::read_to_string(path)
        .with_context(|| format!("reading config from {}", path.display()))?;
    toml::from_str(&raw)
        .with_context(|| format!("parsing config at {}", path.display()))
}
```

- Use `.with_context(|| ...)` (lazy) when the message allocates; `.context("literal")` otherwise.
- **Context names the operation, not the error.** `"reading config from /etc/app.toml"` — not `"failed to read file"`, which the inner error already said.
- Add context at every layer that knows something the layer below did not. Not more, not fewer. The chain is the stack trace you get to design.
- `anyhow::bail!("...")` for an early return; `anyhow::ensure!(cond, "...")` for a precondition. Both beat a hand-written `return Err(anyhow!(...))`.

Recovering a typed error from an `anyhow::Error` is possible but is a smell:

```rust
if let Some(OrderError::NotFound(id)) = err.downcast_ref::<OrderError>() { ... }
```

If you find yourself doing this, the function that erased the type should not
have. Push the `anyhow` boundary outward.

## What never belongs in a signature

| Anti-pattern | Why it fails | Instead |
| --- | --- | --- |
| `Result<T, String>` | caller can only string-match; no `source()` chain | typed enum |
| `Result<T, Box<dyn Error>>` in a `pub` fn | not `Send + Sync` by default, cannot be matched | typed enum, or `anyhow` if truly a binary |
| `Option<T>` for a fallible operation | discards *why* — "no rows" and "connection died" become the same `None` | `Result<Option<T>, E>` |
| `Result<T, ()>` | strictly worse than `Option` | `Option`, or a real error |
| A single `MyError { message: String }` struct | a typed error that is a `String` wearing a struct | variants |

`Result<Option<T>, E>` is the right shape for "look this up": `Ok(Some(x))`
found, `Ok(None)` absent, `Err(e)` broken. Collapsing absent into `Err` forces
every caller to match an error variant for a normal outcome.

## Panic vs. `Result`

Return a `Result` when the caller could plausibly do something about it or
when the input came from outside the process. Panic only for a broken
invariant inside your own code — an index you just computed, a state machine
reaching an impossible arm.

- `expect("message")` over `unwrap()`, always. The message states the
  invariant, in the present tense: `expect("config is validated at startup")`,
  not `expect("failed")`.
- A library panicking on bad *caller input* is a bug. A library panicking on
  its own broken invariant is correct.
- Document it. `# Panics` in the doc comment is part of the contract.
- `#![cfg_attr(not(test), deny(clippy::unwrap_used, clippy::expect_used))]`
  where the crate must not panic at all; then the few legitimate sites carry
  an explicit `#[allow]` and a reason in the commit.
- `catch_unwind` is not error handling. It is for FFI boundaries and thread
  supervision, and it does not work under `panic = "abort"`.

## Partial failure in a collection

The default is all-or-nothing, and `collect` does it for you:

```rust
let orders: Result<Vec<Order>, OrderError> = rows.iter().map(Order::try_from).collect();
```

When partial success is the actual requirement, say so in the type rather than
logging-and-skipping in the loop:

```rust
let (parsed, failed): (Vec<_>, Vec<_>) = rows.iter().map(Order::try_from).partition_result();
```

Silently dropping failures inside a `filter_map(|r| r.ok())` is how a nightly
job processes 4 of 4000 records for a month without anyone noticing. If you
drop, count what you dropped and log the count.

## Errors at an HTTP boundary

Map the typed error to a status once, in one place, and never let the internal
message reach the client:

```rust
impl IntoResponse for OrderError {
    fn into_response(self) -> Response {
        let status = match self {
            OrderError::NotFound(_) => StatusCode::NOT_FOUND,
            OrderError::WrongState { .. } => StatusCode::CONFLICT,
            OrderError::PaymentRejected { .. } => StatusCode::BAD_GATEWAY,
            OrderError::Database(_) => StatusCode::INTERNAL_SERVER_ERROR,
        };
        if status.is_server_error() {
            tracing::error!(error = ?self, "request failed");
        }
        (status, Json(ProblemDetail::from_status(status))).into_response()
    }
}
```

Two rules hold here regardless of framework: **log the full chain server-side
exactly once**, at the boundary that converts it, and **send the client a
shape that carries no internals** — RFC 7807 `ProblemDetail` is the default.
Logging at every layer on the way up produces one incident with nine
stack-shaped log lines and no way to count occurrences.

## Reviewing error handling

- Does any `pub` signature return `String`, `Box<dyn Error>`, or `anyhow` from a library crate?
- Does every enum variant correspond to something a caller branches on?
- Does any `?` cross a layer without gaining context?
- Is there an `unwrap()` outside tests, or an `expect` whose message is not an invariant?
- Does any error message interpolate a struct that could hold a secret?
- Is a failure swallowed by `let _ =`, `.ok()`, or `filter_map(Result::ok)`?
- Is the same failure logged at more than one level?
- On a published crate: is the error enum `#[non_exhaustive]`?
