---
name: driving-nextbi-jira-with-jira-cli
description: Use when running `jira` (ankitpokhrel/jira-cli) against the NextBI Jira at jira8.nextbi.ru — listing or viewing issues, moving an issue's status, adding a blocked-by/blocks link, running JQL, opening a ticket in the browser — and when a command hangs on empty output, a status move is rejected as "invalid transition state", a link points the wrong way, a transition 400s on a required `issuelinks` field, or the token stops resolving from `pass`.
---

# Driving NextBI Jira with jira-cli

Server is old (8.13.1): basic auth only, self-signed CA, non-standard statuses. The CLI is one binary; the sharp edges are the config and the workflow.

## The instance

- `jira8.nextbi.ru` → `192.168.5.105`, internal only, HTTPS behind `NEXTBI-CA` (not in system trust store).
- **Jira Server 8.13.1** — predates Personal Access Tokens (8.14+). No `/rest/pat`, no API token to generate. Auth is AD **username + password over basic auth**. `auth_type: basic`, never `bearer`.
- Server sends the leaf cert only; the CA lives at an LDAP-only AIA. So `insecure: true` in config (or install `NEXTBI-CA` into the trust store and set it false).

## Auth: token comes from `pass`, not a file

The "API token" is just the AD password. Keep it encrypted; a fish function injects it per call:

```fish
function jira
    JIRA_AUTH_TYPE=basic JIRA_API_TOKEN=(pass show nextbi/ad | head -1) command jira $argv
end
```

Username is `nextbi/ad-login` (`i.ivanchuk`). gpg-agent must be warm — a cold agent fails with `gpg: decryption failed: No such file or directory`. Warm it with `pass show nextbi/ad >/dev/null` in the same shell.

Config lives at `~/.config/.jira/.config.yml`. Regenerate with:

```fish
JIRA_API_TOKEN=(pass show nextbi/ad|head -1) jira init \
  --installation local --auth-type basic --insecure --force \
  --server https://jira8.nextbi.ru --login i.ivanchuk --project NEXTBI --board NEXTBI
```

`jira init` auto-detects custom fields but **misses the Russian-named epic fields**. Patch after:

```fish
yq -i '.epic.name="customfield_10002" | .epic.link="customfield_10000"' ~/.config/.jira/.config.yml
```

## Quick reference

| Goal | Command |
|---|---|
| Who am I | `jira me` → `i.ivanchuk` |
| My open issues (TUI) | `jira issue list -a(jira me)` |
| My open issues (text) | `jira issue list -a(jira me) --plain` |
| Filter by status | `jira issue list -a(jira me) -s"IN PROGRESS BACKEND"` |
| Raw JQL escape hatch | `jira issue list -q'status IN ("IN PROGRESS BACKEND","DEV TEST BACKEND") AND text ~ "backup"'` |
| View a ticket | `jira issue view NEXTBI-15057 --comments 5` |
| Open in browser | `jira open NEXTBI-15057` |
| Move status | `jira issue move NEXTBI-15057 "To blocked"` |

## The list is a TUI by default

Bare `jira issue list` takes over the screen (arrows move, `Enter` opens, `v` detail, `o` browser, `q` quit). "Nothing happens after Enter" usually means it rendered the TUI and you expected text. Add `--plain` for pipeable text; add `--columns KEY,STATUS,SUMMARY` to trim.

## Statuses and types are non-standard — quote them exactly

This project's workflow uses per-discipline states, not the Jira defaults:

`IN PROGRESS BACKEND`, `DEV TEST BACKEND`, `REVIEW BACKEND`, `MERGED BACKEND`, `BLOCKED BACKEND`, `CANCELLED BACKEND`, `TO DO BACKEND`, `DONE BACKEND`. Issue types likewise: `Backend Task`, `Frontend Task`, `Analytics Task`, `Эпик`, `Ошибка` (Bug), `Пользовательская история` (Story). Pass them verbatim, quoted.

## `move` wants the transition NAME, not the target status

```fish
jira issue move NEXTBI-15057 "BLOCKED BACKEND"   # ✗ invalid transition state
jira issue move NEXTBI-15057 "To blocked"        # ✓ transition name
```

On the error, the CLI prints the available transition names — `To blocked`, `To dev test`, `To do`, `Cancelled`. Use those.

## Links: direction is everything, "Blocks" is just the type

The link type is `Blocks`; whether it reads *blocks* or *is blocked by* depends on which side each issue is on. In the REST payload:

- our issue **blocks** X → `inwardIssue: X`, `outwardIssue: our-issue`
- our issue **is blocked by** X → `inwardIssue: our-issue`, `outwardIssue: X`

Verify from the issue's own view before trusting a bulk run:

```fish
jira issue view NEXTBI-15057 | grep -i block
```

A wrong-direction link is deleted + recreated, not edited (`DELETE /rest/api/2/issueLink/<id>`).

## Bulk / link / transition: drop to REST

jira-cli has no bulk mode and cannot create links. For fan-out (link N issues, transition N issues), curl the REST API directly — same basic auth, `-k` for the cert:

```fish
set u (pass show nextbi/ad-login|head -1); set p (pass show nextbi/ad|head -1)
set base https://jira8.nextbi.ru/rest/api/2
for k in NEXTBI-15057 NEXTBI-15056
    curl -sk -u "$u:$p" -X POST "$base/issueLink" -H 'Content-Type: application/json' \
      -d "{\"type\":{\"name\":\"Blocks\"},\"inwardIssue\":{\"key\":\"NEXTBI-12251\"},\"outwardIssue\":{\"key\":\"$k\"}}"
    set tid (curl -sk -u "$u:$p" "$base/issue/$k/transitions" | jq -r '.transitions[]|select(.to.name=="BLOCKED BACKEND")|.id')
    curl -sk -u "$u:$p" -X POST "$base/issue/$k/transitions" -H 'Content-Type: application/json' -d "{\"transition\":{\"id\":\"$tid\"}}"
end
set -e p
```

Transition ids differ by source status — resolve `tid` per issue from `/transitions`, never hard-code.

## When a transition 400s on `issuelinks`

```
The field ... (issuelinks) is required on screen but it's not associated with this project/issue type.
Reason: Нельзя перевести в BLOCKED: у задачи должна быть хотя бы одна связь "is blocked by"
```

Two separate gates in one message:

1. A **workflow validator**: the issue must already carry an `is blocked by` link. Create the link first (any client), then transition. This one you can satisfy.
2. A **screen misconfiguration**: `issuelinks` is marked required on the transition screen but its field context isn't bound to this project + issue-type. No payload satisfies it — empty → "required", with the field → "cannot be set". This fails identically in the web UI. It is **not** a client problem; it needs a Jira admin to unmark the field required (or bind its context). Don't burn attempts flipping payloads — confirm the link exists, then escalate.

## `jira open` does nothing / falls through to lynx

The WM sets no `XDG_CURRENT_DESKTOP`, so `xdg-open` runs in generic mode and walks a TUI-browser fallback list instead of the registered default. Set `$BROWSER`:

```fish
set -x BROWSER helium-browser
```

Generic mode reads `$BROWSER` first, so this fixes it; `xdg-settings` default is ignored here.

## Common mistakes

- Using `bearer`/PAT — this server is too old; basic auth only.
- Passing a target status to `jira issue move` instead of the transition name.
- Trusting a bulk link run without checking direction from the issue's own view.
- Retrying an `issuelinks`-required transition in different shapes — gate #2 is server-side, escalate instead.
- Running `jira` in a shell with a cold gpg-agent — warm `pass` first.
