---
name: porting-a-fix-across-diverged-branches
description: Use when moving a commit or a branch's work onto another branch that may have drifted — before running cherry-pick — and when a cherry-pick has already failed with modify/delete conflicts or conflicts across a restructured package layout.
---

# Porting a Fix Across Diverged Branches

A cherry-pick assumes the two branches still agree on where code lives. Check
that before you pick, not through the conflicts.

## Quick reference

| Goal | Command |
|---|---|
| The branch's real base | `git merge-base <mainline> <branch>` |
| What the branch actually changed | `git diff --name-only <mainline>...<branch>` |
| Does the target still have those paths | `git ls-tree -r --name-only <target> \| rg <path>` |
| Is it already there under other SHAs | `git log --oneline <target> \| rg <ticket>` |
| Undo a failed attempt | `git cherry-pick --abort` |

## Verify the paths still exist

This is the step that gets skipped. Take the file list the branch changed and
ask whether the target still has those paths:

```bash
git diff --name-only "$(git merge-base "$TARGET" "$BRANCH")...$BRANCH" \
  | while read -r f; do
      git cat-file -e "$TARGET:$f" 2>/dev/null || echo "absent on target: $f"
    done
```

When a dozen of eighteen files come back absent, cherry-pick has nothing to
apply them to. `CONFLICT (modify/delete): … deleted in HEAD` is that same fact
arriving late and one file at a time.

**A restructured layer means a port, not a transfer.** Reimplementing a fix
against a rewritten API is a different task with a different cost. Say so and
re-price it before starting, rather than discovering it at the tenth conflict.

## Establish the real base first

Do not assume the repository's main development branch is the branch's parent.
Against the wrong mainline, `git log --oneline develop..branch` reported 83
commits and a 137-file diff; the branch had actually forked from a release
branch, and its real content was 21 commits over 18 files. Every later
decision inherits that error.

Two dots and three dots differ, and the difference bites here. `A..B` in
`git diff` compares the two tips, so an advanced mainline cancels the branch's
own changes out — it returned a nine-file list containing none of the files the
branch had rewritten. `A...B` measures from the merge base, which is what "what
this branch changed" means.

## Check whether it already landed

Before porting anything, ask whether the target already has it under different
SHAs — rebased, squashed, or merged through a release. Search the target's log
for the ticket or the subject:

```bash
git log --oneline "$TARGET" | rg "$TICKET"
```

Do not reach for `git cherry` here. It compares patch ids, and a commit whose
hunks were re-contextualised or conflict-resolved on landing has a different
patch id, so `git cherry` reports it as missing: on a branch whose first
fifteen commits were already merged into the mainline, `git cherry` marked
all twenty-one as missing, because every one of them had shifted context
against the advanced mainline. It answers a narrower question than the one
being asked.

## Before the first attempt

Git already remembers where the target stood. `ORIG_HEAD` points at its
pre-pick tip the moment `cherry-pick` starts, and the reflog holds that same
position long after: `git reset --hard ORIG_HEAD` or `git reset --hard @{1}`
gets back without a side file to lose track of. A note in `/tmp` goes stale
the moment a second port starts in the same session; the reflog does not.

Then pick. On failure, `git cherry-pick --abort` and re-plan; do not resolve
conflicts one by one to find out how deep the divergence goes. `--abort` only
unwinds a pick still in progress — once a bad resolution has already been
committed, `git reset --hard` against the reflog entry is the way out.

## Common mistakes

| Mistake | Consequence |
|---|---|
| Opening with `cherry-pick` | Divergence surfaces one conflict at a time |
| Assuming the mainline is the branch's parent | Four times the commits, six times the files |
| `A..B` where `A...B` was meant | The branch's own changes silently vanish from the diff |
| Not checking the target's paths | Hours spent resolving a transfer that was always a port |
| Not checking for an existing merge | Porting work that is already there |
