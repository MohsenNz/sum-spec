# TODO

## Remaining

### Open questions
- [x] More warnings: variants the app never reaches (from `__init`),
      and transitions of one event, on one type, whose sources overlap.
- [x] A warning for transitions that can never happen (their source is
      never reached)? `reachable` in `Check.hs` already knows them.
- [ ] Should the checker build a resolved model of the spec (e.g.
      `SumSpec.Model`) for code generators to consume?

### Closer to an EFSM (`spec/efsm-gaps.md`)
Decide on each gap, one at a time, then move it to `proposals.md`:
- [ ] Where a local transition applies (decided in part; waits for
      derived values in "How updates change values").
- [x] Event inputs.
- [x] Event outputs (decided: none; side effects go in annotations on
      transitions).
- [ ] Guards on data: see "Guards on data, in steps" below.
- [x] How updates change values, Part A: named values.
- [ ] How updates change values, Part B: derived values (replaced by
      arithmetic in targets; see `spec/literal-patterns.md`, question 13).
- [ ] How updates change values, Part C: list updates (form chosen:
      an action clause, `// __remove ts[id]`).
- [ ] Nondeterminism between transitions: first match, once guards
      exist (see gap 5).
- [ ] Values inside a new state (decided in part: see `spec/efsm-gaps.md`
      gap 7; waits for the literal-pattern and arithmetic proposals).

### Guards on data, in steps
The design is in `spec/proposals.md` ("Guard on data", "Prelude"). Do
the steps in order; each one moves `spec-v1.md`, `grammar.ebnf`, the
examples, the golden tests and `CHANGES.md` together.
- [x] 1. Primitive types: `__int`, `__float`, `__text` as the base of an
      atomic in `__atomics` (`Port = __int`). Types only: the atomic is
      still a leaf. No literals or operations yet.
- [x] 2. Guards with pattern predicates only: a `//` clause before `->`;
      read where the source is (after `P =>`, its patterns are arguments
      of `P`); `not`, `and`, `or`; binds no value; the overlap warning
      reads guards. Needs no primitives.
- [x] 3. Guards with comparisons and literals: `== != < <= > >=` on
      names, integer, decimal and string literals, and variants of sums
      without payloads (ordered by declaration); a newtype inherits its
      base's operations, so `Meters` and `Seconds` still don't compare.
      `in` moved to "Later".
- [x] 3b. Named constants: `BatteryLowThreshold = BatteryCharge(15)` as
      a side of a comparison.
- [ ] 4. (Optional, later) Prelude: an embedded `.sumspec` with
      `Bool = True | False`, `Int = __int`, `Float = __float` and
      `Text = __text`; a definition of the same name in the user's spec
      replaces it.

### Versioning
- [ ] Release 0.1.0.0: date it in `CHANGES.md`, then tag `v0.1.0.0`.

### Later (`spec/proposals.md`)
Not part of v1. Each one changes the semantics, so it needs a spec
update before any code:
- [x] `=>` (shared construction path).
- [ ] Naming an element (`Todos[id]#t`).
- [ ] Alternatives in a pattern (`Page(Home | Logs)`).
- [x] Branches on a shared path (`:: App => A -> B => C -> D`), with `/`
      chaining shared paths.
- [ ] Branches on a guard (`f :: T(Int#i) // i < 10 -> ... // i >= 10 -> ...`).
- [ ] Annotations (`__annotations`), also on transitions.
- [ ] Dependent types and generic types.
- [ ] Variant refinement (`PMode.ShowMission = ...`).
- [ ] Several events with one transition (`g, h :: Y -> Z`).
- [ ] `<-` shorthand.
- [x] Named constants (`BatteryLowThreshold = BatteryCharge(15)`): in
      v1 as comparison sides in guards (see "Named constants" in
      `spec/spec-v1.md`).
- [x] Bare binding (`Attempts(#n)`): in v1 (see "Bare binding" in
      `spec/spec-v1.md`).
- [x] Membership in guards (`i in ids`): in v1 (see "Membership" in
      `spec/spec-v1.md`).
- [x] Equality on every type (`==` and `!=` on products, lists and sums
      with payloads): in v1 (see "Comparing values" in `spec/spec-v1.md`).
- [ ] Arithmetic in targets, and in guards with the same expression
      language (see "Arithmetic in targets" in `spec/proposals.md`).
