---
name: environment-scan
description: Use when the user explicitly asks to scan or inventory their machine, environment, or installed CLI tooling — probes the box, proposes the findings that would change Claude's behavior, and on approval records them to a machine-local rule file. Explicit invocation only, never automatic.
---

# Environment Scan

Claude starts every session knowing nothing about the machine it runs on.
It reaches for `grep` on a box with `rg`, writes `export X=y` into a fish
shell, and suggests `mvn` where no Maven exists. This skill collects what
matters once and keeps it.

**Explicit invocation only.** A full scan shells out heavily. Never run it
unprompted, never on a schedule, never at session start.

## Run the scan

```
bash ~/.claude/skills/environment-scan/scan.sh
```

The script probes and emits; it never writes and never decides. All
judgment below is yours.

## The recording bar

A finding earns a line only if **Claude would act differently knowing it**.

- `rg` present — never reach for `grep`.
- Shell is fish — `export X=y` and `&&` chains are bash-isms.
- No `gradle` on PATH — check for `./gradlew` before suggesting a build.

Firefox being installed changes nothing. The full inventory is not the
artifact; the behavior delta is. Most `present` lines in the report are
noise and get dropped.

Each recorded line states **the fact and its consequence**. A fact without
a consequence is exactly the noise this bar exists to filter.

```markdown
- Shell is fish — `export X=y` and `&&` chains are bash-isms; use `set -x X y`.
- `rg` (14.1.0) — use it over `grep`; respects .gitignore by default.
- No `gradle`/`mvn` on PATH — check for `./gradlew` before suggesting a build command.
```

## Where findings land

One test decides it: **does this stay true after `cd` somewhere else?**

- **Yes** — shell, package managers, installed binaries. Goes to
  `~/.claude/rules/environment.md`, machine-local, loaded every session.
- **No** — "this repo's tests need Docker running", "this repo generates
  jOOQ sources at build time". Goes to the current project's memory
  directory as a `reference` entry with the documented frontmatter and a
  `MEMORY.md` pointer line.

Never write the machine inventory into this repo. It is public and other
people install it; their sessions would inherit a stranger's environment as
if it were guidance.

## Approval is one diff

Show exactly the lines to add, remove or change in
`~/.claude/rules/environment.md`. The user approves wholesale or names
lines to drop. **Write nothing before approval.** First run has no existing
file, so the diff is the whole file — one round trip either way.

State which bucket each finding is headed for in that same diff, so global
and project-memory writes are both visible before either happens.

**Hand edits survive.** Never regenerate the file. Parse its existing
finding lines, compare against the fresh scan, propose only line-level
changes. A line the user wrote that no probe produces is left alone — you
cannot tell a hand-written line from a drifted one, so do not guess.

## Drift on re-run

Read the existing file first. Report three things and nothing else:

- **New** — a tool now present that clears the recording bar.
- **Gone** — a recorded tool that no longer exists. Propose removal: a rule
  file claiming `rg` exists on a machine without it is worse than silence.
- **Changed, when it matters** — `rg` 14.1.0 to 14.1.1 is noise, suppress
  it. A major bump that changes flags, or JDK 21 to 25, earns a line.

An unchanged machine gets "no drift" and nothing else. Silence is the
expected result of most re-runs.

**Version skew.** If the recorded `SCAN_VERSION` is lower than the
script's, say so and treat the run as a fresh scan rather than a drift
comparison — probes that did not exist last time would otherwise read as
newly-installed tools.

## Suggestions

Also report what is **missing** that would change the work if present.
Separate section, never installed automatically, each with the concrete
command for the machine's actual package manager as the scan found it.

The bar is higher than for recording: **name what it changes about the
work, not what the tool is.**

- Good: "`yq` would let me edit `.gitlab-ci.yml` in place instead of
  hand-editing YAML."
- Noise: "`bottom` is a nicer `top`."

A swap that is preference rather than capability — `podman` where `docker`
already works — does not qualify. If nothing clears the bar, say "no gaps"
and stop.
