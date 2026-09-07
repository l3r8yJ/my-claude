# Codex compatibility

Read and follow `CLAUDE.md` and `RUST.md` beside this file at the start of
every session. They are the shared source of engineering conventions for
both Claude Code and Codex. Resolve these paths relative to this file, not
the project being worked on. Do not edit this guidance repository when a
task concerns another project.

The installer exposes the same `skills/` directories through
`~/.agents/skills/`. Use their `SKILL.md` instructions when relevant. Resolve
scripts and supporting files relative to the skill's actual directory;
references to `~/.claude/skills/<name>` mean the installed skill directory
on Codex as well.

When a skill names a Claude-specific tool, use the available Codex
equivalent: read a skill's `SKILL.md` to invoke it, use shell/file tools for
Bash/Read/Write/Edit, and use a supported user-input tool or a plain question
for `AskUserQuestion`. Use available agent tools for explicitly requested
subagent workflows. If a required capability is unavailable, explain the
limitation rather than pretending it ran.

`feature-development` requires a separate Superpowers installation. Resolve
`superpowers:<name>` to the corresponding installed Superpowers skill. Do
not silently skip a required stage when that dependency is missing.

If `~/.claude/rules/environment.md` exists, read it for the shared machine
inventory. Treat shell identities, versions, and tool availability as
observations from that scan; the current session's environment takes
precedence. The environment-scan skill remains explicit-invocation only.
