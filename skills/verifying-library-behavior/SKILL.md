---
name: verifying-library-behavior
description: Use when a claim about a third-party library's runtime behavior is load-bearing for correctness and is being inferred from documentation, annotations, or a method name rather than observed — before writing a comment, KDoc, or commit message that asserts how the library behaves.
---

# Verifying Library Behavior

Make "I checked" mean inspection, not inference.

## Core rule

If your KDoc, commit message, code comment, or error string asserts a
mechanism, you must have observed that mechanism. An assertion you have
not verified is worse than silence: it survives into the codebase and
the next reader trusts it.

## Techniques, cheapest first

Escalate only as far as the claim requires. Most claims settle at step
1 or 2.

1. `javap -p` on the jar from the dependency cache. Settles signatures,
   `final`, `vararg`, generic bounds. Often sufficient and takes
   seconds.

   ```bash
   javap -p -cp ~/.gradle/caches/modules-2/files-2.1/<group>/<artifact>/<ver>/*/<artifact>-<ver>.jar \
     com.example.SomeClass
   ```

2. Decompile when control flow matters — which branch a method takes,
   what a short-circuit returns, whether an overload delegates.
3. Render the actual output. For a query builder, log or render the
   SQL rather than trusting method names; for a serializer, print the
   payload.
4. Read generated sources, not the annotations that produced them.
   Annotation-processor output under `build/generated/**` is what
   runs; the annotations are a request.
5. Build a throwaway harness reproducing the failure mode, when the
   claim is about behavior under conditions your tests do not create —
   pooling, concurrency, ordering, empty inputs.

## When it is worth it

Not every call. The trigger is load-bearing *and* inferred: the answer
changes what you write, and you have not seen it happen. Two
supporting signals raise the odds it is worth the minute it costs: the
library sits between your code and something external (a database, a
wire format), or an emulation or compatibility layer is involved,
where the documented API and the executed behavior are deliberately
different things.

## Anti-pattern

Concluding "these two paths are equivalent" from reading both and
finding no difference. An equivalence claim needs a case where they
*would* differ, tried. Reading proves only that you found no
difference — it does not prove there is none.

## Worked examples

- A method looked like it took a single lambda; `javap` showed
  `vararg`, so trailing-lambda syntax could not compile. Prevented a
  "cleanup" that would have failed at twelve call sites.
- A pagination helper was assumed to compute totals independently of
  the returned rows; decompiling showed it short-circuits to an empty
  page, so any out-of-range page reported a zero total. This was a
  live regression.
- A builder call named `returningResult` was assumed to emit a
  `RETURNING` clause; rendering the SQL showed an emulation on a
  different mechanism. The behavior was correct; every comment
  describing it was wrong.
- A build plugin was assumed to filter tests by filename pattern;
  unzipping and disassembling it showed no such filter, dissolving a
  whole category of feared breakage.
- Mapper annotations were assumed to describe the mapping; reading the
  generated implementation showed which fields were actually read,
  settling whether a fixture change could affect assertions.
- A connection-scoped id lookup was assumed safe; a throwaway
  round-robin connection provider reproduced the wrong-id failure in
  three lines and proved the fix.
