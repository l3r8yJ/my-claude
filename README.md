# my-claude

Shared `CLAUDE.md` engineering guidance for Kotlin projects, plus global
skills for guidance that's too narrow or example-heavy to keep loaded every
session:

- `skills/kotlin-test-writing-rules` — jtcop rule conventions for JUnit5 test classes
- `skills/mapstruct-converter-conventions` — Spring `Converter`/MapStruct/`ConversionService` conventions
- `skills/nextbi-analytics-contracts` — working in the NextBI analytics contracts repo (OpenAPI/Kafka contract-first, codegen, versioning)

## Install

```
git clone https://github.com/l3r8yJ/my-claude.git
cd my-claude
./install.sh
```

This symlinks `CLAUDE.md` into `~/.claude/CLAUDE.md`, symlinks each skill
under `skills/` into `~/.claude/skills/`, and adds a Claude Code
`SessionStart` hook that runs `git pull --ff-only` in this repo before each
session, so you always get the latest guidance automatically. Safe to
re-run; it won't duplicate the hook or clobber existing files
(it backs up any existing real `CLAUDE.md` or skill directory to a
timestamped `.bak.<timestamp>` first — your old guidance won't be read by
Claude Code anymore once symlinked, but nothing is deleted).
