---
name: driving-gitlab-with-glab
description: Use when running `glab` against a self-hosted GitLab — merge requests (create, view, diff, approve, merge, checkout), issues, CI pipelines and jobs (status, trace, retry, play a manual deploy), releases, `glab api` for anything with no porcelain, and repo/auth setup — and when `glab` targets the wrong host or branch, a push shows no pipeline, a status move or MR command 401s, or a command reports a different ref than the one you pushed.
---

# Driving GitLab with glab

One binary for merge requests, issues, pipelines and raw API. The sharp edges are the host it points at, keying pipelines by SHA, and resolving names to ids before acting.

## Hosts and auth (self-hosted, plain http)

Two instances, both over **http** not https: `gitlab.nextbi.ru` (default) and `gitlab-master.nextbi.ru`. Authed as `i.ivanchuk`. gitlab.com has no token and 401s.

```bash
glab config get host                              # which GitLab am I hitting
glab <cmd> --hostname gitlab-master.nextbi.ru     # target the other instance
glab auth status                                  # token still valid?
```

`glab config set` writes repo-local `.git/glab-cli/config.yml` unless given `-g` (global). Inside a repo, glab infers the project from the `origin` remote — outside one, pass `-R group/project`.

## Pick the object, resolve its id, then act

`glab` porcelain covers the common paths; `glab api` reaches everything else. Field with `jq -r` before printing — a raw MR/pipeline/job object is hundreds of lines of context for three values.

| Area | Goal | Command |
|---|---|---|
| MR | List mine | `glab mr list --assignee=@me` |
| MR | Open / create | `glab mr create --fill --draft` |
| MR | View + notes | `glab mr view <iid> --comments` |
| MR | Diff | `glab mr diff <iid>` |
| MR | Check out locally | `glab mr checkout <iid>` |
| MR | Approve / merge | `glab mr approve <iid>` · `glab mr merge <iid> --squash --remove-source-branch` |
| Issue | List / view | `glab issue list --assignee=@me` · `glab issue view <iid>` |
| Issue | Create / close | `glab issue create --fill` · `glab issue close <iid>` |
| CI | Status of current branch | `glab ci status` |
| CI | List pipelines | `glab ci list --ref <branch>` |
| CI | Trace a job live | `glab ci trace <job_id>` |
| CI | Retry / cancel | `glab ci retry <id>` · `glab ci cancel <id>` |
| Release | List / view | `glab release list` · `glab release view <tag>` |
| Anything else | Raw API | `glab api "projects/:id/<path>"` |

`:id` in an `api` path is the URL-encoded current project — glab substitutes it. `@me` resolves to the authed user.

## Merge requests: iid, not branch

MR commands take the **iid** (the `!123` number), not a branch name. Find it from the branch:

```bash
glab mr list --source-branch "$(git branch --show-current)" | head
glab api "projects/:id/merge_requests?source_branch=$(git branch --show-current)&state=opened" \
  | jq -r '.[] | "!\(.iid) \(.title) [\(.state)]"'
```

`glab mr merge` refuses while pipelines are running or approvals are missing — read `glab mr view <iid>` first; the block is a rule, not a glab bug.

## CI: key pipelines by SHA, not by ref

With an open MR there may be **no branch pipeline at all** — only a `merge_request_event` one on `refs/merge-requests/<iid>/head`. The manual jobs live on whichever pipeline exists; don't hunt for a separate push pipeline.

The `sha` filter matches the **full 40 characters** only. A short SHA returns an empty list that reads exactly like "nothing ran":

```bash
glab api "projects/:id/pipelines?sha=$(git rev-parse HEAD)" \
  | jq -r '.[] | "\(.id) \(.status) \(.source) \(.ref)"'
```

An empty result seconds after a push means the pipeline does not exist *yet* — poll before concluding it triggered nothing. Merged-results pipelines carry the SHA of an internal merge ref, so the filter never finds them; ask the MR instead:

```bash
glab api "projects/:id/merge_requests/<iid>/pipelines" \
  | jq -r '.[] | "\(.id) \(.status) \(.source) \(.sha[0:8])"'
```

## The `--branch` flag does not exist

Both natural spellings are wrong; the ref flag is `--ref`:

```
$ glab ci list --branch feature/X       # Unknown flag: --branch.
$ glab ci list -b feature/X             # -b is a DATE bound: "cannot parse feature/X as 2006"
```

## Did the stage pass

```bash
glab api "projects/:id/pipelines/$PIPELINE/jobs?per_page=100" \
  | jq -e '[.[] | select(.stage == "build")] | length > 0 and all(.[]; .status == "success")'
```

The `length > 0` guard matters: `all` over an empty array is vacuously true, so a mistyped stage name would otherwise report success. If a whole stage looks absent rather than failed, it may be a `trigger:` job whose work happens downstream — `/jobs` never lists those, `/bridges` does.

## Resolve a job, never type its name

A `parallel: matrix` job renders as `job_name: [VALUE]`. Match on the distinguishing substring and read the id out; echo the full name back before playing it — a matrix of environments differs by one substring, and the wrong element deploys to the wrong stand:

```bash
glab api "projects/:id/pipelines/$PIPELINE/jobs?per_page=100" \
  | jq -r '.[] | select(.name | test("pmss120")) | "\(.id) \(.status) \(.stage) \(.name)"'
glab api --method POST "projects/:id/jobs/<job_id>/play"
```

Read the config rather than guessing what a matrix expands to or what gates a job:

```bash
yq '.deploy_to.parallel.matrix[]' .gitlab-ci.yml
yq '.deploy_to.needs, .deploy_to.rules' .gitlab-ci.yml
```

`yq` reads the file literally — it does not resolve `extends`, `!reference` or `include`, so a `null` often means the key lives on the parent job. A deploy that `needs: build` stays unplayable while the build is red, however manual it looks.

## Waiting

Poll in a bounded background loop until `success`, `failed` or `canceled`. Never block the session on a deploy or a merge. For the shape of that loop — deadline, pre-sleep, terminal failure — see `reviewing-a-blocking-wait`.

## Common mistakes

| Mistake | Consequence |
|---|---|
| Trusting the push remote's hostname | The API host can differ; `--hostname` picks the other instance |
| Forgetting `-g` on `config set` | Setting lands repo-local in `.git/glab-cli/`, gone in another clone |
| Passing a branch to an `mr` command | MR commands want the iid (`!123`), not a branch name |
| `--branch` / `-b` for a ref | Unknown flag, or a date parse error — use `--ref` |
| Short SHA in `?sha=` | Empty list read as "no pipeline ran" |
| Hunting for a branch pipeline | With an open MR there may only be an MR one |
| Typing a matrix job's rendered name | POST 404s, or hits a neighbouring environment |
| `jq` stage check without `length > 0` | Empty selection reports success |
