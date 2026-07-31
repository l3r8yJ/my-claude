---
name: rust-async-service-conventions
description: Use when building or reviewing an async Rust service on tokio and axum - state and dependency injection, extractors, tower middleware, tracing setup, graceful shutdown, timeouts and retries, blocking work, cancellation safety, config, and health probes.
---

# Async Service Conventions (tokio + axum)

## Shape of a service

```
src/
  main.rs          runtime, config, wiring, shutdown — and nothing else
  config.rs        one struct, parsed once, validated at startup
  routes/          one module per resource; handlers only
  domain/          business logic; no axum, no sqlx types
  infra/           db, http clients, message producers
  telemetry.rs     tracing subscriber setup
```

`main.rs` builds the world and hands it to the router. A handler that reads an
environment variable, or a domain function that takes a `StatusCode`, has
leaked a layer.

## State and dependency injection

One `AppState`, cloned per request, holding cheap-to-clone handles:

```rust
#[derive(Clone)]
struct AppState {
    orders: OrderRepository,
    payments: Arc<dyn PaymentGateway>,
    config: Arc<Config>,
}

let app = Router::new()
    .route("/orders/{id}", get(get_order))
    .route("/orders", post(create_order))
    .with_state(state);
```

- `PgPool`, `reqwest::Client` and `Sender` are already `Arc` inside — clone
  them directly, do not wrap them in another `Arc`.
- Wrap in `Arc` only what is genuinely expensive or not `Clone` (a `dyn`
  trait object, a large config).
- **Never `Arc<Mutex<AppState>>`.** It serializes every request through one
  lock. If a field needs interior mutability, put the lock on that field and
  hold it for the shortest possible time — never across an `.await`.
- Prefer a concrete type over `Arc<dyn Trait>` until a second implementation
  exists. "For testing" is not a second implementation when a `wiremock`
  server or a container gives you the real thing.

`FromRef` lets a handler extract one field instead of the whole state:

```rust
impl FromRef<AppState> for OrderRepository {
    fn from_ref(state: &AppState) -> Self { state.orders.clone() }
}
```

## Handlers

A handler extracts, delegates, and converts. It is three to ten lines.

```rust
async fn get_order(
    State(orders): State<OrderRepository>,
    Path(id): Path<OrderId>,
) -> Result<Json<OrderResponse>, OrderError> {
    let order = orders.find(id).await?.ok_or(OrderError::NotFound(id))?;
    Ok(Json(OrderResponse::from(order)))
}
```

- **Extractor order matters.** Body-consuming extractors (`Json`, `Form`,
  `String`, `Bytes`) must come last; everything else borrows from parts.
  Getting this wrong is a compile error, but the message is unhelpful — check
  argument order first.
- Return `Result<T, E>` where `E: IntoResponse`. Never return a bare
  `StatusCode` from deep in the call stack; the error type carries the meaning
  and one `IntoResponse` impl decides the status. See `rust-error-handling`.
- Reject bad input at the extractor. A custom `ValidatedJson<T>` extractor
  that runs `validator` and returns a `ProblemDetail` on failure keeps the
  check out of every handler.
- Handlers take domain types, not `serde_json::Value`. Parsing is the
  boundary's job.
- Do not put business logic in a handler. If it has a `match` on domain state,
  it belongs in `domain/`.

## Middleware, in the right order

`tower` layers apply **bottom-up** for requests: the last `.layer()` added is
the outermost. Order is not cosmetic — a timeout inside a retry retries the
timeout; a timeout outside it kills the whole retry budget.

```rust
let app = Router::new()
    .merge(routes())
    .layer(
        ServiceBuilder::new()
            .layer(TraceLayer::new_for_http())
            .layer(RequestIdLayer::default())
            .layer(TimeoutLayer::new(Duration::from_secs(30)))
            .layer(RequestBodyLimitLayer::new(2 * 1024 * 1024))
            .layer(CompressionLayer::new()),
    )
    .with_state(state);
```

`ServiceBuilder` applies top-down, which reads the way you think — prefer it
over stacked `.layer()` calls for anything beyond two layers.

Non-negotiables for a public listener: a **request body limit** (default is
unbounded, which is a memory DoS), a **global timeout**, and a **request id**
propagated into the trace and echoed in the response.

## Tracing, not logging

```rust
tracing_subscriber::registry()
    .with(tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| "info,tower_http=debug".into()))
    .with(tracing_subscriber::fmt::layer().json())
    .init();
```

- `#[tracing::instrument(skip(self, pool), fields(order_id = %id))]` on the
  functions worth a span. `skip` anything large or secret — an instrumented
  function records **all** its arguments by default, which is how a password
  or a whole request body reaches the log.
- Structured fields, never interpolation: `info!(order_id = %id, amount =
  amount.cents(), "order shipped")`. `%` is `Display`, `?` is `Debug`.
- Levels: `error!` for something a human must act on, `warn!` for degradation
  that recovered, `info!` for a lifecycle event, `debug!` for a per-request
  detail. If everything is `info`, nothing is.
- Log a failure **once**, at the boundary that handles it. Logging at each
  layer on the way up turns one incident into nine lines.
- JSON in production, `fmt::layer().pretty()` behind a config flag locally.

## Graceful shutdown

A service that drops in-flight requests on SIGTERM loses writes during every
deploy.

```rust
async fn shutdown_signal() {
    let ctrl_c = async { signal::ctrl_c().await.expect("ctrl_c handler installs") };
    let terminate = async {
        signal::unix::signal(signal::unix::SignalKind::terminate())
            .expect("SIGTERM handler installs").recv().await;
    };
    tokio::select! { _ = ctrl_c => {}, _ = terminate => {} }
}

axum::serve(listener, app)
    .with_graceful_shutdown(shutdown_signal())
    .await
    .expect("server runs");
```

Handle **SIGTERM**, not just Ctrl-C — SIGTERM is what Kubernetes and systemd
send. Then, in order: stop accepting, let in-flight requests finish under a
bounded drain deadline, close the database pool (`pool.close().await`), flush
the producer and the trace exporter. A `TaskTracker` plus a `CancellationToken`
from `tokio-util` handles background tasks the same way.

## Background tasks

```rust
let tracker = TaskTracker::new();
let shutdown = CancellationToken::new();

tracker.spawn({
    let shutdown = shutdown.clone();
    async move {
        loop {
            tokio::select! {
                _ = shutdown.cancelled() => break,
                _ = interval.tick() => reconcile(&pool).await,
            }
        }
    }
});
```

- Every spawned task is either awaited at shutdown or explicitly documented as
  fire-and-forget in the commit. A `JoinHandle` dropped on the floor is a task
  whose panic nobody sees.
- A panic in a spawned task kills only that task. If the task is load-bearing,
  supervise it — check the `JoinHandle`, restart or shut down.
- Never `spawn` in a loop over user-controlled input without a bound. Use a
  `Semaphore` or `buffer_unordered(N)`.

## Blocking work

Blocking the async executor is the classic production incident: one CPU-bound
or file-reading call stalls every task on that worker thread.

- CPU-bound (hashing, compression, image work), or a synchronous library:
  `tokio::task::spawn_blocking`.
- Long-running CPU work: `rayon`, with a `oneshot` channel back.
- File I/O: `tokio::fs` (which is `spawn_blocking` underneath) — a
  `std::fs::read` in a handler is blocking.
- **Never hold a `std::sync::Mutex` guard across an `.await`.** It is either a
  deadlock or a stalled worker. Use `tokio::sync::Mutex` when the lock must
  span an await, and prefer restructuring so it does not.
- `clippy::await_holding_lock` catches the common case — leave it on.

## Timeouts, retries, and clients

Every out-of-process call has a timeout. There is no exception; a client with
no timeout is a hang waiting for a bad afternoon.

```rust
let http = reqwest::Client::builder()
    .timeout(Duration::from_secs(10))
    .connect_timeout(Duration::from_secs(2))
    .pool_idle_timeout(Duration::from_secs(90))
    .build()
    .expect("http client builds");
```

- Build **one** `reqwest::Client` at startup and clone it. Constructing one
  per request creates a new connection pool per request and leaks TLS
  handshakes.
- Retry only idempotent operations, only on transient failures (connect
  errors, 502/503/504, timeouts), with exponential backoff **and jitter**, and
  a bounded attempt count. Retrying a non-idempotent POST is how a customer
  gets charged three times.
- The inner per-attempt timeout must be shorter than the outer budget:
  `TimeoutLayer(30s)` outside, `RetryLayer(3)` inside, 5s per attempt.
- Add a circuit breaker or `ConcurrencyLimitLayer` on a dependency that can
  brown out, so a slow dependency does not consume every task in your process.
- Prefer a typed client struct per external service, in `infra/`, exposing
  domain-shaped methods. A handler should never build a URL.

## Cancellation safety

An `.await` in axum can be dropped at any point — the client disconnected, the
timeout fired. Everything after that await never runs.

```rust
let mut tx = pool.begin().await?;
sqlx::query!("update accounts set balance = balance - $1 where id = $2", amount, from).execute(&mut *tx).await?;
sqlx::query!("update accounts set balance = balance + $1 where id = $2", amount, to).execute(&mut *tx).await?;
tx.commit().await?;
```

That is safe: a drop between the two statements rolls the transaction back.
What is **not** safe is state mutated in memory between awaits, or a
`tokio::select!` branch that loses data when its future is dropped mid-poll —
`recv()` on an mpsc is cancel-safe, a hand-rolled read-into-buffer usually is
not. When a section must not be interrupted, `tokio::spawn` it and await the
handle, so cancellation of the caller does not cancel the work.

## Config

One struct, parsed once at startup, failing loudly:

```rust
#[derive(Debug, Deserialize)]
struct Config {
    database_url: SecretString,
    #[serde(default = "default_port")]
    port: u16,
    #[serde(with = "humantime_serde")]
    request_timeout: Duration,
}
```

- Environment variables (via `figment`, `config`, or `envy`) with a typed
  struct — never `env::var` scattered through the code.
- **Fail at startup, not at first use.** A missing database URL should stop
  the process in the first second, not produce a 500 an hour later.
- Wrap secrets in `secrecy::SecretString` so a stray `{:?}` cannot print them,
  and never `#[derive(Debug)]` a plain-`String` password field.

## Health and readiness

- `/health` (liveness): returns 200 if the process is alive. **No dependency
  checks** — a database blip must not make Kubernetes kill your pods.
- `/ready` (readiness): checks that dependencies are reachable, so traffic
  stops arriving while they are not.
- `/metrics`: Prometheus via `metrics-exporter-prometheus`, on a separate
  listener or behind an internal route — never on the public router.

## Reviewing an async service

- Is there a timeout on every outbound call, and a body limit on the listener?
- Is SIGTERM handled, and does shutdown drain in-flight work?
- Any blocking call — `std::fs`, a sync client, CPU work — on the async path?
- Any lock held across an `.await`?
- Any `spawn` whose `JoinHandle` is dropped, or unbounded spawning per input?
- Does `#[instrument]` capture an argument that could hold a secret?
- Is a `reqwest::Client` built per request?
- Is a retry applied to a non-idempotent operation?
- Is the same error logged at more than one layer?
- Does `/health` check dependencies it should not?
