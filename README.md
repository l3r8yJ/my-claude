# my-claude

Shared `CLAUDE.md` engineering guidance for Kotlin projects, plus global
skills for guidance that's too narrow or example-heavy to keep loaded every
session:

- `skills/kotlin-test-writing-rules` — jtcop rule conventions for JUnit5 test classes
- `skills/mapstruct-converter-conventions` — Spring `Converter`/MapStruct/`ConversionService` conventions
- `skills/jooq-repository-pattern` — jOOQ data access on `jooq-starter` (repository per table, pagination, Liquibase codegen)
- `skills/nextbi-analytics-contracts` — working in the NextBI analytics contracts repo (OpenAPI/Kafka contract-first, codegen, versioning)

## Requirements

`bash`, `git`, and `jq`. The installer checks for `git` and `jq` and exits
without changing anything if either is missing.

## Install

```
git clone https://github.com/l3r8yJ/my-claude.git
cd my-claude
./install.sh
```

This does three things:

- Links `CLAUDE.md` into `~/.claude/rules/kotlin-spring.md`, so the guidance
  loads in every session **without touching your own `~/.claude/CLAUDE.md`**.
  If your system does not support symlinks (Windows without Developer Mode),
  it instead appends a single `@.../CLAUDE.md` import line to your
  `~/.claude/CLAUDE.md`, creating that file only if it does not exist.
- Links each directory under `skills/` into `~/.claude/skills/`.
- Adds a Claude Code `SessionStart` hook that runs `git pull --ff-only` in
  this repo before each session, so you get the latest guidance
  automatically. If that pull fails — local commits, no network, moved
  directory — the hook says so at the start of your session instead of
  leaving you silently out of date.

It is safe to re-run and never overwrites anything it did not create. If a
file or directory already exists where a link would go, it is left alone and
the installer warns you.

If you installed an earlier version that symlinked `~/.claude/CLAUDE.md`
directly, re-running `./install.sh` removes that symlink and switches you to
the `rules/` mechanism, so the guidance is not loaded twice.

## Uninstall

```
./remove.sh
```

Removes the rule link, the skill links, the import line if one was added, and
this repo's `SessionStart` hook. If an earlier install left a legacy
`~/.claude/CLAUDE.md` symlink pointing into this repo, that is removed too.
Anything it did not create is left untouched. It does not delete the clone
itself — `rm -rf` this directory afterwards if you want it gone.

## Tests

```
bash tests/run.sh
```

Runs `install.sh` and `remove.sh` against throwaway `HOME` directories and
asserts the resulting state. Exits non-zero if any check fails.
