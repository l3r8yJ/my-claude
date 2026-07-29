---
name: verifying-library-behavior
description: Use when a claim about runtime behavior is load-bearing for correctness and is being inferred from documentation, annotations, a method name, or a run of passing attempts rather than observed — before writing a commit message, error string, or test name that asserts a mechanism.
---

# Verifying Library Behavior

Make "I checked" mean inspection, not inference.

## Core rule

If your commit message, error string, test name, or MR description
asserts a mechanism, you must have observed that mechanism. An assertion
you have not verified is worse than silence: it survives into the
codebase and the next reader trusts it.

## Techniques, cheapest first

Escalate only as far as the claim requires. Most claims settle at step
1 or 2.

1. Ask the running system, when one is reachable. It outranks the
   artifact, and it is one request — but only once the deployment is
   confirmed to be the same build as the artifact under discussion; a
   service running an older release settles nothing about the code on
   disk. Judge by status and headers, never the body: a single-page-app
   catch-all answers unknown paths with 200 and HTML, so an endpoint
   that does not exist looks like one that works.

2. `javap -p` on the jar from the dependency cache. Settles signatures,
   `final`, `vararg`, generic bounds. Often sufficient and takes
   seconds.

   ```bash
   javap -p -cp ~/.gradle/caches/modules-2/files-2.1/<group>/<artifact>/<ver>/*/<artifact>-<ver>.jar \
     com.example.SomeClass
   ```

3. Decompile when control flow matters — which branch a method takes,
   whether an overload delegates.
4. Render the actual output. For a query builder, log or render the
   SQL rather than trusting method names; for a serializer, print the
   payload.
5. Read generated sources, not the annotations that produced them.
   Annotation-processor output under `build/generated/**` is what
   runs; the annotations are a request.
6. Build a throwaway harness reproducing the failure mode, for behavior
   under conditions your tests do not create — pooling, concurrency,
   ordering, empty inputs.

## When it is worth it

Not every call. The trigger is load-bearing *and* inferred: the answer
changes what you write, and you have not seen it happen. Two signals
raise the odds it earns the minute it costs: the library sits between
your code and something external, or an emulation or compatibility
layer is involved — cases where documented and executed behavior
deliberately differ.

## Anti-pattern

Concluding "these two paths are equivalent" from reading both and
finding no difference. An equivalence claim needs a case where they
*would* differ, tried. Reading proves only that you found no
difference — it does not prove there is none.

Concluding "that was noise" from a run of passing attempts. A rare
failure is evidence of a narrow window, not of noise — settle it with a
deterministic probe of the invariant, not a longer series. If "this is
noise" changes what you write or what you fix, it needs a probe.

## Worked examples

- A builder call named `returningResult` was assumed to emit a
  `RETURNING` clause; rendering the SQL showed an emulation on a
  different mechanism. The behavior was correct; every comment
  describing it was wrong.
- Mapper annotations were assumed to describe the mapping; reading the
  generated implementation showed which fields were actually read,
  settling whether a fixture change could affect assertions.
- A connection-scoped id lookup was assumed safe; a throwaway
  round-robin connection provider reproduced the wrong-id failure in
  three lines and proved the fix.
- An endpoint's HTTP method was inferred by pairing a path constant with
  a method constant from the same disassembled interface. The pairing was
  wrong and the request returned 405; the response's `Allow` header had
  named the method all along.
- A stress test failing once in roughly a dozen runs was dismissed as a
  shared-mock artifact. A three-line deterministic probe showed the
  production code handed out a borrow on a closed resource, turning a
  dismissed flake into a confirmed race.
