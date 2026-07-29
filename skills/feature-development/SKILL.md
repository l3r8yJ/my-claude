---
name: feature-development
description: Use when building a new feature in a Kotlin/Spring service from a description — drives the whole path from brief to merged branch through interrogation, design, plan, build, review and retrospective, with four hard human gates. Supersedes bare superpowers:brainstorming for feature work. Not for bug fixes, pure refactors, or one-line config edits.
---

# Feature Development

**For feature work this skill runs instead of bare
`superpowers:brainstorming`.** Brainstorming still runs — as stage 2 inside
this chain, not as the first thing reached for. The stages before it exist
because for a Kotlin/Spring service the same four dimensions decide the
design every time, and a feature that silently skips one of them is where
the rework comes from.

A description field cannot stop another skill from firing, and
`superpowers:using-superpowers` names brainstorming as the process skill
that comes first. So expect both to match. **If brainstorming fires first
on feature work, stop and restart here at stage 0** — its questions are a
subset of stage 1's, and answering them twice is the failure this ordering
exists to prevent.

**Not this skill:** a bug fix (that is `superpowers:systematic-debugging`),
a refactor that adds no observable behavior, a one-line config edit. Say so
and drop out rather than running five stages over a two-line change.

## Stages

| # | Stage | Ends at |
|---|---|---|
| 0 | Recon | — |
| 1 | Interrogation | **Gate A** — brief approved |
| 2 | Design | **Gate B** — spec approved |
| 3 | Plan | **Gate C** — plan approved |
| 4 | Build | **Gate D** — tests green, branch diff shown, nothing merged or pushed |
| 5 | Close | harvest, retrospective |

Stage 2 delegates to `superpowers:brainstorming`, stage 3 to
`superpowers:writing-plans`, stage 4 to
`superpowers:subagent-driven-development`.

**Know what the delegates already do, or you will run them twice.**
Brainstorming ends by invoking `superpowers:writing-plans` itself — that
*is* stage 3, so do not invoke it again when brainstorming returns.
`subagent-driven-development` ends with a whole-branch review on the most
capable model and then invokes
`superpowers:finishing-a-development-branch` — that is the integration
decision, so stage 5 does **not** re-run `requesting-code-review` or
`finishing-a-development-branch`. Stage 5 owns only what no delegate
covers: the harvest and the retrospective.

**Hand stage 2 the brief.** Invoke brainstorming with the brief path and
say the interrogation is already done. Without that it re-asks what stage 1
answered, and a user who answers the same question twice stops trusting the
chain. Its job here is design — architecture, components, data flow — not
requirements.

**Stage 0 is recon.** Read the repo before asking anything: build files,
module layout, the code nearest the described feature. Inline, no
subagents, cheap. Its output is the dimension triage in stage 1, not a
report for the user.

## Gates are hard stops

At each gate, name the gate, show exactly what is being approved, and wait.

A gate is never inferred as passed. Not from silence, not from an
unrelated user message, not from "the next step is obvious anyway".

Gate D means the test command was **run**, its output shown, and the
whole-branch diff shown. Stage 4's implementers commit as they work — that
is how `subagent-driven-development` operates and it is fine. What Gate D
holds back is **integration**: nothing merged, nothing pushed, no PR
opened until the user has seen the tests pass and the branch diff.

A fifth halt is not positional. Any stage that discovers a premise from an
earlier stage is false — code assumed dead turns out to have callers, an
endpoint assumed to exist does not — stops and reports instead of
improvising around it. See [[writing-halt-gates-into-plans]].

## Parallelize by default

Work that can run in parallel **must**, not may.

Stage 1's research goes out as one message containing every subagent
question. Stage 4 dispatches implementers concurrently wherever their file
sets are disjoint — the general ban on parallel implementers exists to
prevent write conflicts, and disjoint files have none. Sequencing is what
needs a stated reason, not parallelism: "simpler one at a time" is not one.

Two things stay serial regardless. Commits, because there is one git index
and one writer — parallel agents write files, the controller commits after
they land. And the gates.

## Model choice is the user's

Before the first subagent dispatch of a stage, **ask which model to run
them on.** Stage 1's research agents and stage 4's implementers are
separate asks; the work differs, so the right tier does too. Propose a
default with its reasoning — transcribing prose the plan already contains
is cheap-tier work, design judgment is not — and let the user override it.

Never dispatch without asking, and never omit the model parameter: an
omitted model silently inherits the session's, which is usually the most
expensive tier available.

## Branch

The ticket ID is the first thing stage 1 pins down; the commit scope needs
it regardless. On Gate A passing, create `feature/TICKET-XXX` off `main`
before touching code.

- Already on `feature/TICKET-XXX` — reuse it.
- On `main` — branch from it.
- On a different feature branch — **stop and ask.** Never branch off
  unrelated work by accident.

**Repos with no ticket system.** Not every repo has one. Check before
demanding a ticket: `git log --oneline -30`. If existing subjects carry
scopes (`feat(PROJ-12):`), a ticket is required and asking for it is right.
If none of them do, the repo has no ticket system — use a short kebab slug
of the feature instead (`feature/outbox-relay`), and commit with a bare
type (`feat: add the outbox relay`). **Never invent a ticket ID to satisfy
the format**, and never block the chain waiting for one that does not
exist. In that case the hard floor is the slug, not a ticket.

## Interrogation

Order: **recon, then research, then ask.** Never ask the user what the
repository can answer.

**Dimension triage.** Four seeds:

1. **Contract surface** — GraphQL SDL, OpenAPI, Kafka message schema.
   Contract-first, so this decides everything downstream.
2. **Persistence shape** — new tables or columns, migration, which
   repositories, transaction boundaries, soft delete, indexing, backfill of
   existing rows.
3. **Async and failure** — publishes and consumes, idempotency, retries,
   outbox, timeouts, what a partial failure leaves behind.
4. **Done criteria and test strategy** — the observable outcome that proves
   the feature works, the scenario that walks it end to end, what is out of
   scope.

After recon, mark each seed *applies*, *skipped*, or *needs research*. The
seeds are a floor, not a ceiling — generate feature-specific questions too.
A pricing feature needs rounding and currency questions no seed covers.

**Hard floor.** Two things are never skipped: the feature's identifier —
its ticket ID, or a kebab slug where the repo has no ticket system, see
`## Branch` — and the observable outcome that proves the feature works.
Everything else is skippable *with a stated reason*.

**Research dispatch.** Every *needs research* region becomes a subagent
question, and all of them go out **in a single message** so they run in
parallel. Use `Explore` for broad sweeps, `cavecrew-investigator` when a
compressed `file:line` table is enough. Give each agent one concrete
question, not a topic: "which repositories write to the orders table", not
"look into orders".

**Then ask.** Whatever research left open goes to the user in batched
rounds — one `AskUserQuestion` call per round, up to four related
questions, recommended option first. Two rounds is the target, three when
the feature is genuinely tangled. Skip a round that would only confirm
something already answered, and say it was skipped.

**Invoke, do not paraphrase.** When a dimension pulls in a skill, use it:
[[jooq-repository-pattern]] for jOOQ data access,
[[migrating-jpa-to-jooq-starter]] when JPA is being replaced,
[[nextbi-analytics-contracts]] for OpenAPI and Kafka contracts,
[[mapstruct-converter-conventions]] for `Converter`/MapStruct work,
[[kotlin-test-writing-rules]] for test strategy,
[[reviewing-across-task-seams]] for the whole-branch pass at close. A claim
about third-party library behavior that the design leans on goes through
[[verifying-library-behavior]] before it enters the brief as fact.

## The brief

`docs/superpowers/briefs/YYYY-MM-DD-<identifier>.md`, in the repo where the
feature is being built — the identifier being the ticket ID or the slug.
It stays **untracked**: it is a brainstorming artifact. Before writing it,
run `git check-ignore docs/superpowers/briefs` and, if the path is not
ignored, add `docs/superpowers/` to `.gitignore` first.

Written at Gate A, appended by later stages:

- **Ticket and a one-line feature statement.** Branch name and commit scope
  both derive from here.
- **Answers by dimension**, plus every feature-specific question generated
  along the way.
- **Skipped dimensions, each with its reason** — "no Kafka: synchronous
  read path". A skip recorded without a reason is a defect in the brief.
- **Research findings** — one section per subagent: the question it was
  given, its answer, `file:line` references. This is the only place those
  reports survive the agent that produced them.
- **Open questions** — what neither the user nor the codebase settled,
  carried forward explicitly instead of forgotten.
- **Gate log** — one line each: `Gate A approved 2026-07-29`.

Later stages read the brief instead of re-deriving it. The spec, plan and
task reports keep their usual superpowers paths — `specs/`, `plans/`,
`.superpowers/sdd/` — and the brief links to them, so one file indexes the
chain.

**Recovery.** On invocation, glob for the identifier, not the full name —
`docs/superpowers/briefs/*-TICKET-XXX.md`. The date prefix is the day the
brief was created, so a chain resumed a week later will not match on
today's. If a brief exists, read it, report which gates are already logged,
and resume from the next stage rather than restarting the interrogation.
This is why the brief is a file and not a section of context.

## Close

Stage 4's delegate already ran the whole-branch review and already invoked
`superpowers:finishing-a-development-branch` for the integration decision.
Do not repeat either. Where the branch carried several tasks, add one pass
with [[reviewing-across-task-seams]] — it hunts defects that live between
task scopes, which the per-task reviews structurally cannot see.

Every commit on the branch follows Conventional Commits, scoped to the
ticket (`feat(TICKET-123): …`) or bare where the repo has no ticket system,
with no mention of any AI tool. The brief gets its last gate-log line and
stays untracked.

### Skill harvest

After the merge decision, ask whether the feature surfaced reusable
knowledge: a trap that cost real time, a library behaving against its own
documentation, a pattern this codebase repeats. If so, propose a new skill
and invoke `superpowers:writing-skills`.

Always a proposal, never automatic — a one-off does not become a skill.
This sits at close rather than earlier because the lesson has to be proven
by shipping. Being post-Gate-D, declining it never blocks a merge.

### Retrospective

The last act. Read back the brief's gate log, the task reports, and any
review findings, then interrogate the run itself:

1. **Where did this chain stumble?** A gate that fired too late, a question
   that belonged in stage 1 but surfaced during build, a research region
   never dispatched, a dimension wrongly skipped. Name the concrete moment
   it cost time.
2. **Which existing skill was wrong or thin?** One whose guidance the code
   then contradicted, or that was silent where it should have spoken. Name
   the skill, the passage, and what the run showed instead.
3. **What deserves a new skill?** Same bar as the harvest: proven by
   shipping, repeats across features.

Write it into the brief as `## Retrospective` and surface the proposals.
**Nothing auto-edits a skill.**

Two disciplines stop this from becoming a proposal generator that emits
noise after every feature:

- **Evidence bar.** Every proposal cites what happened in *this* run.
  "Could be clearer" is not a finding.
- **Empty is a valid result.** "Chain ran clean, no proposals" is the
  expected outcome most of the time. Say that plainly rather than
  manufacturing three items.

**Repo boundary.** The feature branch is in the service repo; the skills
live in the my-claude clone. Report the proposals and, if accepted, apply
them in that clone as its own commits — never on the feature branch, which
would smuggle unrelated edits into the merge request.

Find the clone rather than guessing at it: this skill is installed as a
symlink, so `readlink -f ~/.claude/skills/feature-development` resolves to
`<clone>/skills/feature-development`. If that path is not a symlink, the
install used a copy — ask for the clone path instead of searching the
filesystem for it.
