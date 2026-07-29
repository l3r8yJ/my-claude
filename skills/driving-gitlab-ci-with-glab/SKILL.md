---
name: driving-gitlab-ci-with-glab
description: Use when working with GitLab CI from the terminal through glab — locating the pipeline for a commit that was just pushed, checking whether a stage passed, or triggering a manual job such as a deploy — and whenever a pipeline for a known-good push appears to be missing.
---

# Driving GitLab CI with glab

Key pipelines by SHA, resolve job ids by substring, act on the id.

## Quick reference

| Goal | Command |
|---|---|
| Which GitLab is the API hitting | `glab config get host` |
| Pipeline for a commit | `glab ci list --sha "$(git rev-parse <ref>)"` |
| Recent pipelines, every ref | `glab ci list` |
| Pipelines for one branch | `glab ci list --ref <branch>` |
| Jobs in a pipeline | `glab api "projects/:id/pipelines/<id>/jobs?per_page=100"` |
| Run a manual job | `glab api --method POST "projects/:id/jobs/<job_id>/play"` |

Project fields with `jq -r` before printing. A raw pipeline or job object is
hundreds of lines of context for three values.

## The branch flag does not exist

Both spellings that read naturally are wrong:

```
$ glab ci list --branch feature/X
Unknown flag: --branch.

$ glab ci list -b feature/X
Parsing time "feature/X" as "2006-01-02T15:04:05Z": cannot parse "feature/X" as "2006"
```

`-b` is a date bound. The ref flag is `--ref`.

## Key by SHA, not by ref

With an open merge request there may be **no branch pipeline at all** — only a
`merge_request_event` one on `refs/merge-requests/<iid>/head`. Do not go hunting
for a separate push pipeline to find the deploy job on; the manual jobs are on
whichever pipeline exists.

The `sha` filter matches the **full 40 characters** only. A short SHA returns an
empty list, which reads exactly like "nothing ran":

```bash
glab api "projects/:id/pipelines?sha=$(git rev-parse HEAD)" \
  | jq -r '.[] | "\(.id) \(.status) \(.source) \(.ref)"'
```

An empty result seconds after a push means the pipeline does not exist *yet*.
Poll before concluding the push triggered nothing.

SHA keying has one blind spot: merged-results pipelines carry the SHA of an
internal merge ref, not the pushed commit, so the filter finds nothing however
long you wait. Ask the merge request instead — it lists every pipeline of both
kinds, newest first:

```bash
glab api "projects/:id/merge_requests/<iid>/pipelines" \
  | jq -r '.[] | "\(.id) \(.status) \(.source) \(.sha[0:8])"'
```

## Did the stage pass

```bash
glab api "projects/:id/pipelines/$PIPELINE/jobs?per_page=100" \
  | jq -e '[.[] | select(.stage == "build")] | length > 0 and all(.[]; .status == "success")'
```

The `length > 0` guard matters: `all` over an empty array is vacuously true, so
a mistyped stage name would otherwise report success.

If a whole stage looks absent rather than failed, it may be a `trigger:` job
whose work happens downstream. `/jobs` never lists those; `/bridges` does.

## Resolve the job, never type its name

A `parallel: matrix` job renders as `job_name: [VALUE]`. People ask for it by a
shorthand that matches no job. Match on the distinguishing substring and read
the id out:

```bash
glab api "projects/:id/pipelines/$PIPELINE/jobs?per_page=100" \
  | jq -r '.[] | select(.name | test("pmss120")) | "\(.id) \(.status) \(.stage) \(.name)"'
```

Echo the full resolved name back before triggering. A matrix of environments
differs by one substring, and playing the wrong element deploys to the wrong
stand.

Read the config instead of guessing what a matrix expands to or what gates a
manual job:

```bash
yq '.deploy_to.parallel.matrix[]' .gitlab-ci.yml
yq '.deploy_to.needs, .deploy_to.rules' .gitlab-ci.yml
```

`yq` reads the file literally — it does not resolve `extends`, `!reference` or
`include`, so a `null` here often means the key lives on the parent job. A
deploy that needs `build` stays unplayable while the build is red, however
manual it looks.

## Waiting

Poll in a bounded background loop until `success`, `failed` or `canceled`.
Never block the session on a deploy.

## Common mistakes

| Mistake | Consequence |
|---|---|
| `--branch` / `-b` | Unknown flag, or a date parse error |
| Short SHA in `?sha=` | Empty list read as "no pipeline ran" |
| Hunting for a branch pipeline | With an open MR there may only be an MR one |
| Typing a matrix job's rendered name | POST 404s, or hits a neighbouring environment |
| `jq` stage check without `length > 0` | Empty selection reports success |
| Trusting the push remote's hostname | The API host can differ from the web host; `--hostname` picks the other |
