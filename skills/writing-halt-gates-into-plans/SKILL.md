---
name: writing-halt-gates-into-plans
description: Use when authoring an implementation plan or task brief where a task rests on a premise the author has not verified — a claim that code is dead, unused, or safe to delete, or any finding derived from a narrow search rather than the full call graph.
---

# Writing Halt Gates into Plans

## 1. The Distinction

An ordinary verification step confirms success *after* the work. A
halt gate checks a *premise before* the work and stops the task when
the premise is false. They look alike on the page — both are a step
with a command and an expected output — but they do opposite jobs.
One asks "did it work". The other asks "should this task exist at
all".

A plan full of verification steps can still walk an agent straight
through a false premise, because nothing in it is allowed to say no.

## 2. Shape

Make the halt explicit, and make the failing condition the
interesting one — the one the step is actually there to catch:

```
Step 1: Run <check>. If it finds anything, STOP and report BLOCKED
rather than proceeding. Only continue if the output is empty.
```

Phrasing carries the weight. "Verify X is unused" invites an agent
to confirm what the author already believes — it reads as a
formality on the way to the real work. "If it finds anything, STOP
and report BLOCKED" makes the discovery a legitimate outcome rather
than an obstacle to push past. Write the stop condition first and
the continue condition second, not the other way around.

## 3. Premises That Need a Gate

Each of these produced a wrong finding in a real review:

- a finding derived from a narrow search, where the author did not
  walk the full call graph
- any claim that something is dead, unused, or safe to delete
- any claim of the form "nothing else uses X"
- a premise inherited from an earlier review rather than
  re-established against the current code
- a claim about a library's behavior that the plan then depends on
  — pair with [[verifying-library-behavior]]

If a task's justification is a sentence like these, the plan needs a
gate immediately before that task, not a promise to double-check
later.

## 4. Invariant Gates — the Second Form

Some regressions do not break anything — they silently shrink scope,
and a green build cannot tell the difference. A rename that stops a
group of tests from being collected still leaves every collected
test passing. The only way to catch it is to have recorded a number
before the change existed to compare against.

The shape: capture a count before the change, do the work, capture
the same count after, and compare. State explicitly, in the plan,
that a green build is not the evidence — the before/after comparison
is.

## 5. Cost and Payoff

A gate costs two lines in a brief: a command and a stop condition.
In the session that motivated this skill, one such gate stopped a
change that would have silently disabled container lifecycle
management across eight test classes. Nothing in the test output
would have flagged it — the containers would simply have restarted
per class instead of being reused, and the failure mode would have
surfaced weeks later as flaky integration tests, with no obvious
link back to the commit that caused it. The gate cost two lines and
caught it before a single line of the change was written.

## 6. When Not to Bother

A premise you established yourself, in this session, by reading the
code, does not need a gate — you already have the evidence. Gates
are for premises that are inherited from an earlier review, inferred
from a narrow search, or assumed because they sound plausible.
Adding a gate to every step regardless dilutes the ones that matter;
reserve them for the claims a task actually depends on.
