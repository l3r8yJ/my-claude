# my-claude

Shared `CLAUDE.md` engineering guidance for Kotlin projects, plus global
skills for guidance that's too narrow or example-heavy to keep loaded every
session:

- `skills/kotlin-test-writing-rules` — jtcop rule conventions for JUnit5 test classes
- `skills/mapstruct-converter-conventions` — Spring `Converter`/MapStruct/`ConversionService` conventions
- `skills/jooq-repository-pattern` — jOOQ data access on `jooq-starter` (repository per table, pagination, Liquibase codegen)
- `skills/migrating-jpa-to-jooq-starter` — replacing Spring Data JPA entities and repositories with `jooq-starter` equivalents
- `skills/nextbi-analytics-contracts` — working in the NextBI analytics contracts repo (OpenAPI/Kafka contract-first, codegen, versioning)
- `skills/verifying-library-behavior` — establishing what a library actually does, by inspection rather than inference
- `skills/writing-halt-gates-into-plans` — stopping a planned task when its premise turns out to be false
- `skills/reviewing-across-task-seams` — whole-branch review for defects that live between task scopes

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

There is no uninstall script — run these steps by hand, in this order. Set
`REPO` to the path of your clone first:

```
REPO=/path/to/your/clone/of/my-claude
```

1. Remove the rule symlink, but only if it still points into this clone:

   ```
   [ "$(readlink ~/.claude/rules/kotlin-spring.md 2>/dev/null)" = "$REPO/CLAUDE.md" ] && rm ~/.claude/rules/kotlin-spring.md
   ```

2. Remove the skill symlinks under `~/.claude/skills/`:

   ```
   for skill_src in "$REPO"/skills/*/; do
     name="$(basename "$skill_src")"
     dst="$HOME/.claude/skills/$name"
     [ "$(readlink "$dst" 2>/dev/null)" = "$REPO/skills/$name" ] && rm "$dst"
   done
   ```

3. If the symlink fallback wasn't available and install appended an import
   line to `~/.claude/CLAUDE.md` instead, strip just that line:

   ```
   if [ -f ~/.claude/CLAUDE.md ] && [ ! -L ~/.claude/CLAUDE.md ]; then
     grep -vxF "@$REPO/CLAUDE.md" ~/.claude/CLAUDE.md > /tmp/claude-md.tmp
     mv /tmp/claude-md.tmp ~/.claude/CLAUDE.md
   fi
   ```

4. If an older install left `~/.claude/CLAUDE.md` itself as a symlink into
   this repo, remove it:

   ```
   [ "$(readlink ~/.claude/CLAUDE.md 2>/dev/null)" = "$REPO/CLAUDE.md" ] && rm ~/.claude/CLAUDE.md
   ```

5. Drop this repo's `SessionStart` entry from `~/.claude/settings.json`. This
   matches on the same anchored string the installer itself uses
   (`contains($repo + "\"")`, not `contains($repo)`), so a sibling clone
   whose path happens to share a prefix with yours is left alone:

   ```
   jq --arg repo "$REPO" '
     if (.hooks.SessionStart | type) == "array" then
       .hooks.SessionStart |= (
         map(.hooks |= map(select(((.command // "") | contains($repo + "\"")) | not)))
         | map(select((.hooks | length) > 0))
       )
     else . end
     | if (.hooks.SessionStart? // []) == [] then del(.hooks.SessionStart) else . end
     | if (.hooks? // {}) == {} then del(.hooks) else . end
   ' ~/.claude/settings.json > /tmp/settings.tmp && mv /tmp/settings.tmp ~/.claude/settings.json
   ```

6. Finally, delete the clone itself:

   ```
   rm -rf "$REPO"
   ```

Anything you did not get from this repo — your own `~/.claude/CLAUDE.md`
content, your own skills, other tools' `SessionStart` hooks — is untouched by
these steps as long as you follow the guards (`readlink` checks, the
anchored `jq` match) as written above.

## Tests

```
bash tests/run.sh
```

Runs `install.sh` against throwaway `HOME` directories and asserts the
resulting state. Exits non-zero if any check fails.
