# my-claude

Personal Claude Code setup for Kotlin/Spring work, installed globally rather
than per-project: one always-loaded `CLAUDE.md` of engineering conventions
(Kotlin idioms, testing defaults, jOOQ and Kafka practice, a ban on
comments), plus ten skills that load on demand.

`install.sh` symlinks both into `~/.claude/`, so a `git pull` in this clone
updates every project at once. A `SessionStart` hook does that pull for you.

## Skills

Guidance too narrow or example-heavy to keep loaded every session lives in
`skills/` instead:

| Skill | Fires when |
| --- | --- |
| `kotlin-test-writing-rules` | Writing or reviewing a Kotlin JUnit5 test class |
| `mapstruct-converter-conventions` | Writing a Spring `Converter` or MapStruct mapper, or calling `ConversionService` |
| `jooq-repository-pattern` | Writing or reviewing a jOOQ repository on `jooq-starter`, or configuring `jooqCodegen` |
| `migrating-jpa-to-jooq-starter` | Replacing a JPA `@Entity`/`JpaRepository` with a jOOQ one, or debugging the failures that migration causes |
| `nextbi-analytics-contracts` | Working in the NextBI analytics contracts repo — OpenAPI or Kafka contracts, codegen, versioning |
| `verifying-library-behavior` | A claim about a library's runtime behavior is load-bearing and inferred from docs rather than observed |
| `writing-halt-gates-into-plans` | Authoring a plan whose task rests on an unverified premise — "this code is dead", "this is safe to delete" |
| `reviewing-across-task-seams` | Reviewing a whole branch whose individual commits were already reviewed |
| `feature-development` | Building a new feature in a Kotlin/Spring service, from description to merged branch |
| `environment-scan` | **Explicit ask only** — "scan my environment", "what tooling do I have" |

All of these fire automatically when the situation matches, except
`environment-scan`, which runs only when asked.

## Requirements

| What | Why | Checked by installer |
| --- | --- | --- |
| [Claude Code](https://github.com/anthropics/claude-code) | Reads `~/.claude/rules/` and `~/.claude/skills/`; nothing here does anything without it | no |
| `bash` | Runs `install.sh` and `tests/run.sh` | no — it's the interpreter |
| `git` | The `SessionStart` hook pulls this repo before each session | yes, exits if missing |
| `jq` | Edits `~/.claude/settings.json` to wire that hook | yes, exits if missing |
| [superpowers](https://github.com/obra/superpowers) | `feature-development` delegates its stages to `superpowers:brainstorming`, `writing-plans`, `subagent-driven-development` and `finishing-a-development-branch` | no |
| intellij-index MCP | Optional. The guidance prefers its symbol lookup and rename tools over text search; without it, Claude falls back to `rg` | no |

The installer checks only `git` and `jq`, and exits without changing anything
if either is missing. Everything else it assumes.

### superpowers

The other nine skills stand alone. `feature-development` does not — it is a
wrapper that hands each stage to a superpowers skill, so without the plugin
installed it stalls at stage 2. Install it in Claude Code with:

```
/plugin install superpowers@claude-plugins-official
```

Skip it if you don't want `feature-development`; the rest of this repo works
either way.

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
