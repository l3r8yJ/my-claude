# my-claude

Shared `CLAUDE.md` engineering guidance for Kotlin projects.

## Install

```
git clone https://github.com/l3r8yJ/my-claude.git
cd my-claude
./install.sh
```

This symlinks `CLAUDE.md` into `~/.claude/CLAUDE.md` and adds a Claude Code
`SessionStart` hook that runs `git pull --ff-only` in this repo before each
session, so you always get the latest guidance automatically. Safe to
re-run; it won't duplicate the hook or clobber an existing `CLAUDE.md`
(it backs up any existing real file to a timestamped `CLAUDE.md.bak.<timestamp>` first — your
old guidance won't be read by Claude Code anymore once symlinked, but nothing is deleted).
