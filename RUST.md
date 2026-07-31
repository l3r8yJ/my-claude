# Shared engineering guidance for Rust projects

This repo also ships five on-demand Rust skills — `rust-error-handling`,
`rust-test-writing-rules`, `rust-async-service-conventions`,
`rust-sqlx-repository-pattern`, and `rust-cli-conventions` — for guidance too
narrow or example-heavy to keep loaded every session. Claude applies them
automatically when relevant.

The comment ban, the unused-code ban, the Conventional Commits format with a
ticket scope, the ban on committing brainstorming artifacts, and the response
style for engineering tasks are stated in the Kotlin guidance but are not
about Kotlin. They apply here unchanged. The rest of this file is what Rust
changes.

IMPORTANT:

- Prefer minimal, targeted changes over broad rewrites.
- Preserve the existing crate's style unless there is a clear reason to change it.

## The comment ban, in Rust

Everything in the general ban holds: no `//`, no `/* */`, no TODO markers, no
section banners, no commented-out code, no blank lines inside function
bodies. `git log` holds the why, `expect`/`assert!` messages hold the
constraint, test names hold the intent.

Rust adds exactly one carve-out, and it is narrow: **`///` and `//!` on the
public items of a library crate that publishes documentation.** Those are not
comments — they are the crate's API surface, they compile (`cargo test`
runs doctests), and they are what a consumer reads on docs.rs. Write them as
you would write a function signature: what it returns, what it panics on,
what it errors on. `# Panics` and `# Errors` sections are load-bearing, not
decorative.

That carve-out does not extend to: private items, binary crates, function
bodies, `#[cfg(test)]` modules, or a `///` that restates the signature
(`/// Returns the name.` above `fn name(&self) -> &str` is litter). If a doc
comment on a public item explains *how* the body works rather than *what the
caller gets*, it is a regular comment wearing three slashes — delete it.

## General engineering defaults

- Prefer simple, readable Rust. The borrow checker already costs the reader
  attention; do not spend more of it on cleverness.
- Follow DRY, but do not introduce a trait, a generic parameter, or a macro
  before there is a second caller. A trait with one implementor is a comment
  that compiles slowly.
- **Unused code is banned — delete it, do not keep it.** A `pub(crate)` fn,
  struct field, variant, dependency, or feature flag with no remaining caller
  gets removed in the same change that orphans it. `cargo +nightly udeps` and
  `cargo machete` find unused dependencies; `#[warn(dead_code)]` finds the
  rest inside a crate. Deleting is safe — `git log -S` is the archive.
- Delete the code and its tests **together**. A `#[test]` is not a caller.
- Before deleting a `pub` item, prove it is unused across the whole workspace
  and not part of a published API: search every crate, plus `build.rs`,
  macros, `#[derive]` inputs, serde `rename` attributes, FFI `#[no_mangle]`
  exports, and anything named in a config or migration file. A published
  crate's `pub` item is a contract — deprecate with `#[deprecated]` first.
- **No `.await` on an out-of-process call inside a loop.** Database queries,
  HTTP requests, message publishes, object-storage round trips — none belong
  in a `for` body. Use the batch form (one `IN (…)` query, one bulk request)
  or gather the futures and drive them with bounded concurrency
  (`futures::stream::iter(..).map(..).buffer_unordered(N).try_collect()`),
  never an unbounded `join_all` over a caller-sized collection. Two round
  trips that stay constant beat N that grow with the data, and a half-failed
  loop leaves partially-applied state with nothing to roll it back. The
  exception is per-item work that exists to give each item its own
  transaction and error boundary — name the function for the isolation it
  buys (`reconcile_each_in_own_transaction`) and justify it in the commit.
- Avoid changing public APIs, wire formats, or schemas unless the task
  requires it. In a published crate, a `pub` signature change is a semver
  break — check with `cargo semver-checks` rather than reasoning about it.
- Consider backward compatibility, migration risk, and operational impact.

## Rust idioms

- **Panics:** production code does not `unwrap()`. Use `?` to propagate,
  `expect("invariant that must hold")` where a panic is genuinely correct and
  the message names the invariant, and `unwrap_or_default()` /
  `unwrap_or_else` where a fallback exists. `unwrap()` is fine in tests,
  `build.rs`, and examples. Deny it where it matters:
  `#![cfg_attr(not(test), deny(clippy::unwrap_used))]`.
- **Indexing panics too.** `v[i]`, `s[a..b]` and integer division are panic
  sites hiding as syntax — prefer `get(i)`, `get(a..b)`, `checked_div`.
- **Errors:** a library returns a typed error (`thiserror`); a binary's `main`
  and its top-level handlers may erase types (`anyhow`/`eyre`). Never
  `Box<dyn Error>` in a public library signature — the caller cannot match on
  it. Full guidance in `rust-error-handling`.
- **Options:** prefer combinators (`map`, `and_then`, `filter`, `ok_or_else`,
  `unwrap_or_default`, `zip`) over `match` on `Option` when the arms are one
  expression each; prefer `let ... else` and `if let` over a `match` with a
  trivial second arm. Prefer `Option<&T>` over `&Option<T>` in arguments.
- **Iterators:** prefer `iter().map().filter().collect()` and the terminal
  operators (`sum`, `min_by_key`, `partition`, `fold`, `any`, `find_map`,
  `flat_map`, `chunks`, `windows`) over a manual `let mut acc` loop. Prefer
  `collect::<Result<Vec<_>, _>>()` over accumulating and checking by hand.
  Reach for `Itertools` only when the standard library genuinely lacks the
  operator — it is a dependency, not a default.
- **Borrowing:** take `&str` not `&String`, `&[T]` not `&Vec<T>`, `impl
  AsRef<Path>` not `&PathBuf` — accept the widest type the body needs. Do not
  `.clone()` to escape a borrow error before trying to shorten the borrow's
  lifetime or restructure the access; a clone in a hot path is a decision,
  not a fix. Do not add a lifetime parameter to a struct before measuring
  that owning the data is a problem.
- **Types over primitives:** prefer a newtype (`struct UserId(Uuid);`) over a
  bare `Uuid` in a signature where a mix-up would compile.
  `#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]` costs nothing and a
  swapped-argument bug costs a night. Derive `serde` traits on the wire type,
  not on the domain type, when they differ.
- **Make illegal states unrepresentable:** prefer an `enum` with data over a
  struct of `Option` fields that are only valid in combinations. Prefer
  exhaustive `match` with no `_ =>` arm over a catch-all, so adding a variant
  fails the build instead of silently falling through. Reserve `_ =>` for
  matching on a `#[non_exhaustive]` type you do not own.
- **Constructors:** prefer `From`/`TryFrom` over an inherent `from_x` method,
  and `Default` over a `new()` with no arguments. A builder is for four or
  more optional fields, not for two.
- **Immutability:** `let` before `let mut`; shadowing before mutation. Reach
  for `Rc<RefCell<T>>` only after a plain owned value and an index have both
  failed — a `RefCell` moves a borrow error from compile time to a panic at
  3am.
- **Strings:** `format!` for building, `push_str` in a loop, `write!` into a
  `String` when the result feeds a writer anyway. Do not `format!` a value
  only to parse it back.
- **Concurrency:** prefer message passing (`mpsc`, `watch`) over shared
  `Mutex` state where the shape allows. Never hold a `std::sync::Mutex` guard
  across an `.await` — use `tokio::sync::Mutex` there, or restructure so the
  lock is not held. Prefer `parking_lot` only with a reason.
- **`unsafe` is a last resort, and it is never undocumented.** Every `unsafe`
  block carries a `// SAFETY:` comment naming the invariant that makes it
  sound — this is the one comment the ban does not reach, because
  `clippy::undocumented_unsafe_blocks` enforces it. Prefer
  `#![forbid(unsafe_code)]` at the crate root and delete it only when a
  specific FFI or performance need arrives with a benchmark.

## Toolchain and build

- `cargo fmt` and `cargo clippy --all-targets --all-features -- -D warnings`
  both pass before anything is called done. Formatting is not a matter of
  taste and clippy findings are not suggestions.
- Pin the toolchain in `rust-toolchain.toml` so CI and every machine agree.
- Set `rust-version` (MSRV) in `Cargo.toml` for a published crate and verify
  it in CI, rather than discovering the break from a user.
- Keep the dependency tree small and justify additions. Prefer a std solution,
  then an already-present dependency, then a new one. Check what a candidate
  drags in (`cargo tree`) before adding it — a small crate with twelve
  transitive dependencies is not a small crate.
- Turn off default features you do not use (`default-features = false`) and
  name what you need; this is where most of a bloated build comes from.
- Use a workspace with `[workspace.dependencies]` for shared versions rather
  than repeating and drifting versions per crate.
- `Cargo.lock` is committed for binaries and workspaces; for a published
  library it does not bind consumers either way — commit it for reproducible
  CI.
- Keep `unsafe`, `panic`, and lint policy in `[lints]` in `Cargo.toml` or a
  crate-root attribute block, not scattered `#[allow]` at each site. An
  `#[allow]` at a call site needs the reason in the commit message.

## Error and boundary handling

- Model expected failures as data — a `Result` with a typed error enum, or a
  domain enum — and reserve panics for programmer error and broken
  invariants. A user sending bad input is not exceptional.
- Validate at the boundary and construct a type that cannot be invalid past
  it, rather than re-checking the same string in four layers.
- Do not swallow errors. `let _ = fallible();` needs a reason in the commit,
  and usually needs a log line instead.
- Add `tracing` spans and events where they are operationally useful; prefer
  structured fields (`tracing::info!(user_id = %id, "…")`) over interpolating
  values into the message.
- Consider timeouts, retries with jittered backoff, idempotency, cancellation
  safety, and backpressure at every out-of-process boundary.

## Testing defaults

- Unit tests live in a `#[cfg(test)] mod tests` beside the code; integration
  tests live in `tests/` and may only use the crate's public API. That split
  is a design signal — if a behavior is unreachable from `tests/`, ask
  whether it should be public or whether it is dead.
- Prefer testing at the boundary: drive the real entry point (an HTTP request
  against the router, a parsed CLI invocation, a consumed message) and assert
  on the observable outcome — the response, the resulting rows, the emitted
  events — rather than reaching into internals.
- Prefer one test that walks a whole workflow over several that each poke one
  step. Lifecycle bugs live between the steps.
- Use `testcontainers` for PostgreSQL, Kafka and friends. Do not substitute
  SQLite for PostgreSQL unless explicitly asked.
- Mock only what you do not control — third-party HTTP (`wiremock`), clocks,
  randomness. Never mock your own repository or database when a container can
  run the real query.
- **Never `sleep` in a test.** A fixed sleep is too short under CI load or too
  long always, and it states nothing about what is being waited for. Poll the
  condition, or use `tokio::time::pause()` and `advance()` to control the
  clock outright.
- Name tests as sentences of behavior (`rejects_expired_token`), not as
  method names (`test_validate`).
- Full conventions in `rust-test-writing-rules`.

## Architecture preferences

- Prefer contract-first for externally visible APIs and event schemas; the
  Rust types are generated from or checked against the contract, not the
  other way round.
- Keep transport, domain, and persistence types distinct, with explicit
  conversions (`From`/`TryFrom`) at each boundary. A `serde` type that is
  also the database row and also the domain model couples three rates of
  change together.
- Prefer explicit SQL (`sqlx`) over an ORM where it improves clarity; see
  `rust-sqlx-repository-pattern`.
- Split a workspace along boundaries that compile independently, not along
  layers that all change together.
