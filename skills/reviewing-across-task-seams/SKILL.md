---
name: reviewing-across-task-seams
description: Use when reviewing a branch of several commits whose individual tasks were already reviewed — a whole-branch or pre-merge review that must find defects living between task scopes rather than re-checking each diff.
---

# Reviewing Across Task Seams

**Premise.** Per-task review is scoped to one task's diff. Some defects
live in the gap between two scopes, and every individually-correct
review passes them. A whole-branch review that re-reads the same diffs
adds nothing — it has to look for a different class of thing.

**Four categories to hunt:**

1. **Producer/consumer seams.** A value computed in task N and
   consumed in task M. Each reviewer verified their half against its
   immediate neighbour; neither compared against the behavior before
   *both* changes. Ask: what did this value look like before the
   first commit in the range, and does it still?
2. **Sedimentary files.** A file edited by three or four tasks. Read
   its *final state* for coherence, not the individual diffs. Each
   edit can be correct while the result reads as layers.
3. **Sibling drift.** A mechanical change applied to N similar files.
   Per-task review sees one file; only a whole-branch pass sees that
   the eighth diverged.
4. **Asserted mechanisms.** Claims in commit messages, KDoc, or error
   strings describing machinery no single task verified end to end.
   Pair with [[verifying-library-behavior]].

**Method.** Review the final state plus the whole-range diff, not the
per-task diffs again. For each heavily-touched file, ask which tasks
edited it and whether their edits compose. Where a task's review
concluded "equivalent", check the equivalence claim against the
*pre-range* behavior rather than the previous task's.

**Worked example** (genericized, and the reason this skill exists): a
refactor swapped a hand-rolled count for a library pagination helper.
The helper derives its total from the returned rows, so an empty
window reports zero. Task N's reviewer confirmed the helper produced
correct totals for in-range pages — true. Task M's reviewer confirmed
the consumer re-wrapped that total faithfully — also true. The
regression is that a page past the end of the data reports "no
results at all" instead of "past the end of N results", and it lived
precisely between the two scopes. It shipped through both reviews and
was caught only by a whole-branch pass that compared against the
behavior before either commit.

Both reviews were correct within their scope. This is not a story
about careless reviewers — it is about what scoped review
structurally cannot see, which is why the whole-branch pass has to
hunt something different rather than re-reading the same diffs.

**What this is not.** Not a second full review. Re-checking what
per-task review already covered wastes the one pass that can see
across scopes.
