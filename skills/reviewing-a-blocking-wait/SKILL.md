---
name: reviewing-a-blocking-wait
description: Use when writing or reviewing a loop that polls for a condition with a sleep in its body — a wait for a remote job, a status poll, a retry loop — including one encountered while reading someone else's diff.
---

# Reviewing a Blocking Wait

Six decisions. Reviewers reliably catch four of them and mis-price the rest.

## The two that get missed

**The pre-sleep is not cosmetic.** `do { sleep; poll } while (!terminal)`
charges the full interval to every call, including the ones whose work was
already finished when the wait began. A ten-second interval turns a one-second
job into an eleven-second job, permanently, for every caller. Reviewers see
this and file it as Minor; it is the defect with the largest blast radius per
character changed. The shape that fixes it:

```kotlin
while (true) {
    val state = poll()
    if (state.isTerminal) return state
    if (System.nanoTime() - deadline >= 0) error("...")
    Thread.sleep(POLL_INTERVAL)
}
```

**A constant named for a timeout that holds an interval is a lie the next
reader believes.** `JOB_AWAIT_TIMEOUT = 10_000` was the poll interval. Someone
raising "the timeout" to an hour would have made the loop slower, not more
patient.

## The four that get caught — one line each

- No overall deadline. The loop pins whatever resource it holds; take the
  deadline from configuration, not a constant.
- Terminal-failure must not exit like success. Throw, carrying the reported
  error, or the caller proceeds as though the work succeeded.
- A failed poll is not a failed job. Log and keep polling to the deadline;
  distinguish "cannot read the state" from "the work failed".
- Let `InterruptedException` propagate. Wrapping it in a domain exception makes
  a cancelled task record as an error wherever the executor discriminates by
  type.

## Before you rewrite it as async

Ask who runs the loop. If the dispatcher blocks on `join()` and tasks are
serialised, making the wait asynchronous buys nothing — the queue was never
going to advance anyway. Virtual threads do not apply to threads built with an
explicit `Thread {}`.

And the sleep is frequently the only interrupt point on the path: socket reads
do not respond to interruption. Deleting it because it "looks bad" makes the
work uncancellable and leaves `@PreDestroy` unable to stop it.

Moving the wait into a coroutine changes the cancellation signal itself: a
`delay()` raises `CancellationException` through suspension points, not
`InterruptedException`. Anything downstream that discriminates by exception
type — an executor recording CANCELLED versus ERROR, a `catch` that swallows
one and not the other — silently changes behaviour. Port the cancellation
contract deliberately or leave the thread blocking.

## Testing it without sleeping in the test

Reviews of this shape almost never say how to test the fix, so the fix ships
untested. Two moves cover it:

- Inject the deadline as configuration and pass `Duration.ZERO`. The deadline
  branch fires on the first pass, with no wall-clock cost, and the assertion is
  on the thrown message rather than on elapsed time.
- For cancellation, let `awaitility` wait until the worker reaches
  `Thread.State.TIMED_WAITING` — that state is only reachable from inside the
  sleep — then interrupt it and assert on the exception type.

## Common mistakes

| Mistake | Consequence |
|---|---|
| Filing the pre-sleep as Minor | Every caller pays the interval forever |
| Naming an interval `TIMEOUT` | The next change tunes the wrong knob |
| Treating a failed poll as a failed job | A network blip abandons work that is still running |
| Wrapping `InterruptedException` | Cancellation is recorded as failure |
| Deleting the sleep to modernise | The wait stops responding to cancellation |
| Testing with a real interval | A slow suite that still proves nothing about the deadline |
