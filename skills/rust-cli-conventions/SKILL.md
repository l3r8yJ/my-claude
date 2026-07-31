---
name: rust-cli-conventions
description: Use when building or reviewing a Rust command-line tool - clap structure, exit codes, stdout vs stderr discipline, piping and TTY detection, colour, progress and verbosity, config precedence, signal handling, testing a binary, and distribution.
---

# Rust CLI Conventions

## The contract a CLI has with a pipe

A command-line tool has two users: a human at a terminal, and a script. The
script is the one that breaks silently, so its contract comes first.

1. **stdout is the result. stderr is everything else.** Data the user asked
   for goes to stdout and nothing else does — no progress, no "Done!", no
   log lines. Diagnostics, prompts, warnings, and progress bars go to stderr.
   The test is `tool > out.json`: if `out.json` needs editing before another
   program can read it, the split is wrong.
2. **The exit code is the API.** `0` means the thing the user asked for
   happened. Non-zero means it did not. A tool that prints "error: not found"
   and exits `0` will be trusted by a `&&` chain and cause an outage.
3. **Detect a TTY, do not assume one.** Colour, progress bars, and interactive
   prompts are for a terminal. `std::io::stdout().is_terminal()` decides;
   piped output gets plain text.

## clap, derive form

```rust
#[derive(Parser)]
#[command(name = "orders", version, about = "Query and manage orders")]
struct Cli {
    #[command(subcommand)]
    command: Command,
    #[arg(long, global = true, env = "ORDERS_CONFIG")]
    config: Option<PathBuf>,
    #[command(flatten)]
    verbosity: Verbosity,
}

#[derive(Subcommand)]
enum Command {
    List(ListArgs),
    Show { id: OrderId },
    Cancel { id: OrderId, #[arg(long)] force: bool },
}
```

- Parse into typed fields — `PathBuf`, an enum via `ValueEnum`, a newtype via
  `FromStr`. A `String` that is immediately parsed in the body has moved the
  error message from clap's clean output to a stack trace.
- `#[arg(long, env = "…")]` gives environment fallback for free and documents
  it in `--help`.
- `#[command(flatten)]` for option groups shared across subcommands.
- Conflicts and requirements are declarative: `conflicts_with`, `requires`,
  `ArgGroup`. Never re-validate flag combinations by hand in `main`.
- `version` from `Cargo.toml` via `#[command(version)]`. Ship the git SHA too
  if the tool is deployed — a bug report saying "1.2.0" from a user running a
  build from an unmerged branch costs an afternoon.
- Add `clap_complete` to generate shell completions and `clap_mangen` for a
  man page. Both are a few lines in `build.rs` and both are expected of a tool
  people install.

Note the derive form is `clap` v4: `#[command]`/`#[arg]`, not v3's
`#[clap(...)]`. Mixed examples on the internet will not compile.

## Exit codes

```rust
fn main() -> ExitCode {
    let cli = Cli::parse();
    match run(cli) {
        Ok(()) => ExitCode::SUCCESS,
        Err(err) => {
            eprintln!("error: {err:#}");
            ExitCode::from(err.code())
        }
    }
}
```

- `fn main() -> ExitCode` over `std::process::exit`, which skips destructors
  and can truncate a buffered stdout.
- `fn main() -> anyhow::Result<()>` is acceptable for a small tool: it prints
  the `Debug` chain and exits `1`. It is not acceptable when callers need to
  distinguish failures.
- Distinguish what a script would branch on. `2` for usage errors (clap's own
  default), `1` for a general failure, and distinct codes for the cases a
  caller acts on — "not found" versus "permission denied" versus "network".
  Document them in `--help` or the man page, then never renumber them.
- `130` for interrupted-by-SIGINT is the shell convention; follow it.
- Never `unwrap()` in `main`. A panic gives a user a stack trace, an exit code
  of `101`, and no idea what to do.

## Output

- **Human by default, machine on request.** `--format json` (or `--json`) that
  emits one well-formed document, plus `--format jsonl` for streaming. Never
  ask a user to parse your table.
- Under `--format json`, *everything* on stdout is JSON — including the error
  case. A tool that prints JSON on success and a bare sentence on failure
  cannot be scripted.
- Keep the default human output stable enough to be readable and unstable
  enough that nobody parses it — which is exactly why the JSON mode has to
  exist.
- Colour through `anstream`/`owo-colors`, off when not a TTY, and honour
  **`NO_COLOR`** and `--color=never|auto|always`. `clap` v4 handles its own
  output; the rest is yours.
- Progress bars (`indicatif`) go to **stderr**, and only when stderr is a TTY.
  A progress bar in a CI log produces ten thousand lines of carriage returns.
- Lock and buffer stdout for anything in a loop:
  `let mut out = BufWriter::new(io::stdout().lock());`. Unbuffered `println!`
  takes a lock and flushes per call, and dominates the runtime of anything
  that prints a lot.
- **Handle `EPIPE`.** `tool | head -1` closes the pipe, and the default
  behavior is a panic on the next write. Match on
  `ErrorKind::BrokenPipe` and exit `0` — the user got what they asked for.

## Errors a human can act on

```
error: could not read config
  caused by: /etc/orders.toml: No such file or directory

  try: orders --config ./orders.toml, or run `orders init` to create one
```

State what failed, why, and what to do next. `{err:#}` on an `anyhow::Error`
prints the whole chain in one line; the alternate `{err:?}` prints it
multi-line with a backtrace when `RUST_BACKTRACE` is set. Details in
`rust-error-handling`.

Suggest, do not guess. If an argument is misspelled, clap already suggests the
correction — do not add a second layer that silently does what it thinks the
user meant.

## Verbosity and logging

```rust
#[derive(clap::Args)]
struct Verbosity {
    #[arg(short, long, action = clap::ArgAction::Count, global = true)]
    verbose: u8,
    #[arg(short, long, global = true, conflicts_with = "verbose")]
    quiet: bool,
}
```

`-v` is debug, `-vv` is trace, `--quiet` suppresses everything but errors. Wire
it into `tracing_subscriber` with an `EnvFilter`, and let `RUST_LOG` override —
a user debugging your tool should not have to learn a second mechanism.
`clap-verbosity-flag` gives you this whole block if you would rather not write
it.

## Configuration precedence

Fixed, and in this order, highest first:

1. command-line flags
2. environment variables
3. a config file (`--config`, then `$XDG_CONFIG_HOME/tool/config.toml` via `directories`)
4. built-in defaults

Any other order surprises someone. Make `--config` on a missing file an error;
make a *default-location* file that is absent a non-event. Never write to the
user's config or cache directory without being asked, and never outside the
XDG paths.

## Interactivity and destructive actions

- A prompt requires a TTY on **stdin**. If stdin is a pipe, do not prompt —
  fail with a message naming the flag that would have answered it (`--force`,
  `--yes`).
- Destructive operations confirm by default and take `--yes` to skip. `--force`
  and `--dry-run` are worth having on anything that deletes or overwrites.
- `--dry-run` prints exactly what would happen, to stdout, in the same format
  as the real run.

## Signals

```rust
ctrlc::set_handler(move || shutdown.store(true, Ordering::Relaxed))
    .expect("signal handler installs");
```

Ctrl-C during a long operation should leave the world consistent: finish or
roll back the current unit, remove partial output files, restore the terminal
(cursor, raw mode, alternate screen) before exiting. Write to a temporary file
and `rename` it into place — `rename` is atomic on the same filesystem, so an
interrupted run leaves either the old file or the new one, never half of one.

## Testing a binary

Drive the real binary. `assert_cmd` runs it as a subprocess so exit code,
stdout, and stderr are all under test:

```rust
#[test]
fn exits_with_two_on_an_unknown_flag() {
    Command::cargo_bin("orders").unwrap()
        .arg("--nope")
        .assert()
        .code(2)
        .stderr(predicate::str::contains("unexpected argument"));
}
```

- Assert the **exit code** on every failure test. It is the part scripts
  depend on and the part nobody checks.
- `assert_fs` for temporary directories and file assertions; `insta` for
  snapshotting help text and formatted output, so an accidental change to
  `--help` shows up as a reviewable diff.
- `Cli::command().debug_assert()` in one test catches malformed clap
  definitions — conflicting names, bad defaults — at test time rather than at
  a user's first invocation.
- Test the pipe: assert that `--format json` output parses, and that nothing
  else contaminates stdout.

## Distribution

- Set `[profile.release] lto = "thin"`, `codegen-units = 1`, `strip = true`
  for a smaller, faster binary. Add `panic = "abort"` only if nothing catches
  unwinds.
- Build against `x86_64-unknown-linux-musl` for a static binary that runs
  anywhere, when the tool has no C dependencies that fight it.
- Publish checksums with the release artifacts. `cargo-dist` generates the
  whole release workflow — installers, checksums, per-platform archives — and
  is worth it the moment a second person installs the tool.
- `cargo install` needs a `rust-version` in `Cargo.toml` so a stale toolchain
  fails clearly instead of erroring deep in a dependency.

## Reviewing a CLI

- Does anything but the result go to stdout?
- Does every failure exit non-zero, and does every distinct failure a caller
  branches on have its own code?
- Is `BrokenPipe` handled?
- Is colour or progress emitted when not a TTY, and is `NO_COLOR` honoured?
- Is there a machine-readable output mode, and does it stay machine-readable on error?
- Does a prompt appear when stdin is a pipe?
- Is stdout locked and buffered in loops?
- Does a destructive command confirm, and is there a `--dry-run`?
- Does an interrupted run leave a partial file behind?
- Is there an `unwrap()` reachable from `main`?
