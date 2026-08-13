---
name: rest-api-conventions
description: Use when adding, naming, reviewing or documenting an HTTP endpoint — a `@RestController`, `@PostMapping`, `ResponseEntity`, an `openapi.yaml` path, a controller test — or when deciding how a list response is paged, how to fetch many records by id without a loop, what a non-CRUD action is called, or whether JSON fields are snake_case.
---

# HTTP API Conventions

RPC over HTTP, addressed the way gRPC transcoding and Google AIP-136 address
custom methods — a collection, a colon, a verb — with response shapes taken
from Spotify's Web API.

**Every endpoint is `POST /v1/<collection>:<verb>`, and every input is in the
JSON body.** No path variables. No query string. The URL identifies the
operation and nothing else; two calls to the same operation have byte-identical
URLs and differ only in their bodies.

```
POST /v1/pets:list
POST /v1/pets:by-id
POST /v1/pets:create
POST /v1/pets:update
POST /v1/pets:delete
POST /v1/orders:cancel
POST /v1/users:login
```

What this costs, stated once so nobody rediscovers it in production: no HTTP
caching, no ETags, no conditional requests, no URL anyone can paste into a
browser, and a bare `/v1/orders:cancel` in every access log and APM trace. Put
the ids into structured log fields, because the path will never carry them.

This skill covers only the decisions that come out different every time they
are made from scratch. Versioning, RFC 7807 error bodies, ISO 8601 UTC
timestamps, string ids, money as an object, string enums, `Idempotency-Key`,
`409` on an illegal transition: keep doing those, they need no help.

A job too slow for a request returns `202` and an operation id; poll it with
`POST /v1/operations:by-id` and stop it with `POST /v1/operations:cancel`. One
flat operations collection for the whole service, never one per resource type.
`status` is an enum (`running` / `succeeded` / `failed`) and the payload lands
in `result` when it succeeds.

## 1. Collection, colon, verb — and the target goes in the body

```
POST /v1/orders:cancel
{ "order_id": "o_31f8", "reason": "customer_request" }
```

Not `/v1/orders/{order_id}:cancel`. Not `?order_id=`. The id is an input like
any other, and it belongs where the other inputs are.

**Collections are flat.** Nothing nests, because nesting is a path variable
wearing a costume. A thing that a caller can list is its own collection with its
own verbs, and the parent it belongs to is a field:

```
POST /v1/pet-photos:list      { "pet_id": "p_7a1f", "limit": 20 }
POST /v1/pet-photos:create    { "pet_id": "p_7a1f", "url": "…" }
POST /v1/tickets:list         { "project_id": "p_42", "limit": 20 }
```

That is the whole test: **can a caller list them?** If yes it is a collection.
If no, it is a verb on the collection that owns the behaviour, and it never
becomes a path segment.

### Use the canonical verb names

The failure this prevents is six people inventing six names for one operation.
Take the name from this list before coining a new one:

| Verb | Operation | Body carries |
|---|---|---|
| `:list` | Paged read, with filters | filters, `limit`, `page_token` |
| `:by-id` | Read one or many by id | `ids` |
| `:create` | Create one | the new resource's fields |
| `:batch-create` | Create many | `items` |
| `:update` | Partial update | target id + fields to change |
| `:delete` | Remove | target id |
| `:search` | Query too complex for `:list` filters | the query |
| `:login` / `:logout` | Open and close a session | credentials / session id |

Anything outside the list is a domain verb. A bare verb when the collection in
the path is already the object — `:cancel`, `:adopt`, `:suspend`. Verb-then-noun
when the verb acts on something other than that collection —
`:preview-certificate`, `:reprice-lines`. Never a preposition, kebab-case
always. Never coin a synonym for a canonical verb — no `:get`, `:fetch`,
`:retrieve`, `:find-by-id`, `:add`, `:remove`, `:modify`, `:patch`.

`:delete` means the resource stops being readable — a later `:by-id` returns
`null` for it. A terminal lifecycle state that stays readable and listable is
not a delete, whatever the business calls it: that is a domain verb
(`:retire`, `:archive`, `:close`) returning the resource in its final state.

`:by-id` and `:create` are deliberate departures from AIP-136, which bans
prepositions and standard-method names in custom verbs. That ban exists to keep
custom methods distinguishable from standard ones; here there are no standard
methods to be confused with, so the reason does not apply.

**Every verb:**

- Names its target `<resource>_id` when there is one (`order_id`,
  `operation_id`), `<resource>_ids` when a verb takes several. Only `:by-id`
  uses the bare `ids`.
- Returns the resource its own body targeted, not `204` — even when the
  operation touched others. `:merge` returns the ticket whose id the caller
  sent, whatever happened to the one it merged into. When the verb creates,
  return `201` and the new resource.
- Returns `202` and an operation id if it cannot finish inside the request —
  this beats every other rule, including `:create`'s `201`. Create the row
  first and return it as the whole body with an `operation_id` field on it —
  not a wrapper around both — so a caller can read it while the work runs. Put
  nothing in the operation's `result` that the resource itself will not tell you.
- Answers the retry question at design time: `Idempotency-Key`, or idempotent by
  construction — `:cancel` on a cancelled order returns `200` with the same
  body, not `409`.

### Spring wiring

```kotlin
@RestController
@RequestMapping("/v1/orders")
class OrderController(private val orders: OrderService) {

    @PostMapping(":cancel")
    fun cancel(@RequestBody request: CancelOrderRequest): OrderResponse =
        orders.cancel(request.orderId, request.reason).toResponse()
}
```

No `@PathVariable` anywhere in the service. The colon sits in a static segment,
so `PathPatternParser` has no capture-plus-literal segment to resolve — the
routing risk that a path-variable style carries is gone. Still write one
`@WebMvcTest` hitting `/v1/orders:cancel` before building the surface out, and
confirm the ingress passes `:` through unmodified; most do, some WAFs do not.

Request types validate their own targets — `@field:NotBlank val orderId: String`
— because there is no path binding to reject a malformed id first.

## 2. One paging object, byte-for-byte, on every `:list`

```json
{
  "items": [],
  "limit": 20,
  "offset": 0,
  "next": "b2Zmc2V0OjIw",
  "previous": null,
  "total": 137
}
```

`next` and `previous` are **opaque page tokens**, not URLs — a URL cannot carry
a body. A client pages by posting the token straight back:

```
POST /v1/pets:list    { "status": "available", "limit": 20 }
POST /v1/pets:list    { "page_token": "b2Zmc2V0OjIw" }
```

A `page_token` carries its own filters. A caller sends the token alone and gets
the next page of the same query; sending a token beside changed filters is a
`400`, not a silently different result.

- `limit` has a default (20) and a hard maximum (50–100). Absent never means all.
- `total` is the count matching the filter.
- Tokens are opaque. Base64 whatever you like inside them, and never document
  it — a client that decodes one has pinned your pagination implementation.

**Cursor variant**, for feeds ordered by time, collections written at the head
while a client pages, and anything where `OFFSET 10000` is a table scan:

```json
{
  "items": [],
  "limit": 20,
  "cursors": { "after": "AaCbD", "before": null },
  "next": "Y3Vyc29yOkFhQ2JE",
  "previous": null,
  "total": null
}
```

`items`, `limit`, `next`, `previous` and `total` appear in both envelopes,
always, so one client handles either — present as `null` when counting is too
expensive or there is no backward page, never omitted. Exactly two keys are
style-specific: `offset` on the offset envelope, `cursors` on the cursor one.

One collection, one paging style, forever. Different collections in one service
may differ — tickets on cursors, their comments on offsets is correct, not a
smell — because the choice follows the write pattern of that collection, and the
shared keys mean a client never has to care.

## 3. `:by-id` is the only read path, and it is positional

```
POST /v1/pets:by-id
{ "ids": ["p_7a1f", "p_deadbeef", "p_3b8d"] }
```

There is no read-one endpoint. Reading one is reading a list of one, which is
what makes the N+1 impossible to write by accident: a caller that needs forty
pets has no per-item endpoint to loop over.

Return **one entry per requested id, in the requested order, `null` where not
found**:

```json
{
  "items": [
    { "id": "p_7a1f", "name": "Rex", "status": "available" },
    null,
    { "id": "p_3b8d", "name": "Buster", "status": "sold" }
  ]
}
```

`items`, the same key the paging object uses. Not a shorter array plus a
`not_found` list — that makes every caller re-match by id, which is the loop
this endpoint existed to delete. Never `404` the whole call because one id was
missing; a request whose ids are *all* missing still returns `200` and a list of
nulls. Cap the batch, publish the number, enforce it:
`require(request.ids.size <= MAX_BY_ID) { "…" }`. The body has no URL-length
limit, so pick the cap from what the query and the response size can carry —
500 is a reasonable default, and it is unrelated to a `:list` endpoint's `limit`.

## 4. `snake_case` in JSON, kebab-case in paths

`created_at`, `order_id`, `total_amount`; `/v1/purchase-orders:list`,
`/v1/pets:preview-certificate`.

Configure it globally — `PropertyNamingStrategies.SNAKE_CASE` — never per-DTO
with `@JsonProperty`. The rule matters less than having one: pick this, and the
drift between an endpoint written today and one written in March disappears.

## 5. `/v1` is the whole prefix

Not `/api/v1`. The `api` segment carries no information — every path in the
service is an API, and a segment that is constant across every route is a
segment that distinguishes nothing. Version first, collection second:
`/v1/pets:list`.

This is the one rule an existing service most often violates on the way in.
When extending a service already serving `/api/v1/...`, do not mix: either the
new endpoints join the old prefix and a migration is scheduled, or the prefix
moves wholesale. Two prefixes for one API is worse than either choice, and
"we'll unify later" is how a service ends up with three.

## 6. Status is two surfaces, never one

Every service eventually grows a request for "one place to see what's going
on", and it arrives as one endpoint. It is two, with **one source of truth
underneath**:

```
StatusSnapshotService            ← reads the cheap sources once
    ├── POST /v1/statuses:list   → product: stages, counters, detail
    └── HealthContributor(s)     → /actuator/health: UP/DOWN only
```

Both surfaces read the same state, so they cannot disagree — the failure this
prevents is a dashboard and a monitor telling on-call two different stories.

**The health vocabulary answers a different question.** `UP`, `DOWN`,
`OUT_OF_SERVICE`, `UNKNOWN` mean *is the service working*, not *what is it
doing*. A failed backup from last night is `UP`: the service is fine, a job
was not. Map a business failure to `DOWN` and the orchestrator restarts the
pod and the probe pulls the instance out of rotation over something that never
touched its health. Business stages live in the product surface; health carries
liveness of dependencies and nothing else.

**Health carries no detail.** Actuator is routinely exposed with weaker
authentication than the API — sometimes none. File paths, backup names, error
text and logs belong in the authenticated product response, never in a health
component.

**The product surface is an ordinary collection.** `statuses` has listable
elements with stable ids, so it gets the standard verbs and the standard
envelope — `POST /v1/statuses:list` and `POST /v1/statuses:by-id`, no special
shape. Give each element the same fields: `id`, `stage` from one service-wide
enum, `native_status` (the component's own value, `null` for aggregates),
`changed_at` — *when the stage changed*, not when it was read, or the client
cannot show "running for 12 minutes" — and a free-form `detail` object for
display only. Clients branch on `stage`; `detail` is for humans.

**One stage vocabulary, mapped, not replaced.** A service that has grown
several lifecycles has several words for one thing — `IN_PROCESS`,
`IN_PROGRESS`, `INSTALLING` all mean running. Fold them into one enum
(`IDLE` / `RUNNING` / `SUCCEEDED` / `FAILED` / `CANCELLED` / `PAUSED`) and
return the original alongside it. Keeping `native_status` is what makes the
unification non-breaking: a client that needs the distinction still has it,
existing endpoints stay untouched, and nothing has to be migrated first.

**A snapshot holds cheap reads only.** Anything that opens a socket — a
connectivity check, a probe of another service — is an *action* a user
triggers, not state to be collected. Put one in the snapshot and it answers in
seconds, flaps whenever any dependency is slow, and degrades the whole response
over one component.

**A snapshot pairs with push, it does not replace it.** SSE and websockets tell
a *connected* client what changed and have no replay; the snapshot answers the
first page load and every reconnect. Deleting the pull endpoint because "events
cover it" loses exactly the window where the client was not listening —
including the case where the service itself restarted.

## Quick reference

| Operation | Call | Body |
|---|---|---|
| List | `POST /v1/pets:list` | filters, `limit`, or `page_token` alone |
| Read one or many | `POST /v1/pets:by-id` | `{"ids": […]}` → positional, `null` for misses |
| Create | `POST /v1/pets:create` | the new resource → `201` |
| Update | `POST /v1/pets:update` | `{"pet_id": …, …fields}` → the updated resource |
| Delete | `POST /v1/pets:delete` | `{"pet_id": …}` |
| Domain action | `POST /v1/orders:cancel` | `{"order_id": …, "reason": …}` |
| Slow job | `POST /v1/pets:reindex` | → `202` + operation id |
| Child collection | `POST /v1/pet-photos:list` | `{"pet_id": …}` |
| What is going on | `POST /v1/statuses:list` | stages + `detail`; health stays in actuator |

## Common mistakes

| Mistake | Fix |
|---|---|
| `POST /v1/orders/{order_id}:cancel` | `POST /v1/orders:cancel`, id in the body |
| `POST /v1/pets:by-id?ids=a,b` | `{"ids": ["a","b"]}` in the body |
| `GET` anything | Every operation is `POST` |
| `POST /v1/pets/{pet_id}/photos:list` | Flat collection: `/v1/pet-photos:list` with `pet_id` in the body |
| `next` returned as a URL | An opaque `page_token` the client posts back |
| `:get`, `:fetch`, `:find-by-id`, `:add`, `:modify` | The canonical name from the table |
| `POST /v1/orders:create-order` — noun repeated | `:create`; the noun is already in the path |
| `:by-id` returns matches plus a `not_found` array | Positional, `null` for misses |
| A different list envelope per endpoint | Copy the paging object above verbatim |
| `:delete` used for a terminal state that stays readable | A domain verb — `:retire`, `:archive`, `:close` |
| `201` from a create that takes minutes | `202` and an operation id; the job rule beats the create rule |
| No validation on a body-carried id | `@field:NotBlank` — nothing rejected it upstream |
| `POST /api/v1/pets:list` | `/v1/pets:list` — `api` distinguishes nothing |
| A business failure mapped to health `DOWN` | `UP` with a `FAILED` stage in the product surface |
| Backup names, paths or logs in `/actuator/health` | Detail belongs in the authenticated response |
| A network probe collected into a status snapshot | It is an action the user triggers, not state |
| Pull status endpoint deleted because "SSE covers it" | Push has no replay; the snapshot serves reconnects |

## Sources

- Spotify Web API — [status codes, error objects, timestamps](https://developer.spotify.com/documentation/web-api/concepts/api-calls)
- Spotify Web API — [paging object, `limit`/`offset`](https://developer.spotify.com/documentation/web-api/reference/get-users-saved-tracks)
- Google AIP-136 — [custom methods and the `:verb` mapping](https://google.aip.dev/136)
- Google AIP-127 — [HTTP and gRPC transcoding, `google.api.http`](https://google.aip.dev/127)
