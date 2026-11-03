# TODO

## Remaining

- [ ] An element can't be named (`Todos[id]#t`), should we allow it?
- [ ] Does transition is the right name?
- [x] Require the two sides of a transition to be states of the same
      type (the same head type: `Page.Home -> Page.Plan`, not
      `Page.Home -> Missions`). Today `spec/spec-v1.md` ("Arguments in
      state patterns") says they don't have to be. Update the spec
      sentence, add the rule to the checker notes in `grammar.ebnf`, add
      the check in `src/SumSpec/Check.hs` with an `error-*` case in
      `test/check/`, and record it in `CHANGES.md` (language). The
      examples already follow the rule.

### Open questions
- [ ] More warnings: states no transition reaches, and transitions
      whose signatures overlap.
- [ ] Should the checker build a resolved model of the spec (e.g.
      `SumSpec.Model`) for code generators to consume?

### Closer to an EFSM (`spec/efsm-gaps.md`)
Decide on each gap, one at a time, then move it to `proposals.md`:
- [ ] Where a local transition applies (decided in part; waits for
      derived values in "How updates change values").
- [x] Warning: a local transition inside a list element that doesn't
      pick the element by key.
- [x] Nested lists: pick an element of an outer list in a pattern
      (element paths).
- [x] Event inputs.
- [ ] Event outputs.
- [ ] Guards on data.
- [x] How updates change values, Part A: named values.
- [ ] How updates change values, Part B: derived values.
- [ ] How updates change values, Part C: list updates (form chosen:
      an action clause, `// __remove ts[id]`).
- [ ] Nondeterminism between signatures.
- [ ] Initial state.
- [ ] Values inside a new state.

### Versioning
- [x] One language version (1.0, in development) until the first
      release; no version checks or "Added in" notes until then.
- [x] Versioning policy (`VERSIONING.md`) and `CHANGES.md`; proposals
      marked additive or breaking.
- [ ] Release 0.1.0.0: date it in `CHANGES.md`, then tag `v0.1.0.0`.
- [x] `__version major.minor` header in spec files (part of 1.0; no
      header means 1.0). The parser rejects versions it doesn't
      implement.

### Later (`spec/proposals.md`)
Not part of v1. Each one changes the semantics, so it needs a spec
update before any code:
- [ ] Several transitions with one signature (`g, h :: Y -> Z`).
- [x] Transition inputs (`f X :: A -> B`).
- [ ] `=>` (shared construction path) and `<-` shorthand.
- [ ] Annotations (`__annotations`).
- [ ] Dependent types and generic types.
- [ ] Variant refinement (`PMode.ShowMission = ...`).
- [ ] Several signatures under one name (input written once).
- [x] Element paths (`Todos[id]`).
- [x] Keyed lists (`[Todo by TodoId]`); element paths need them.
- [x] Lists only as whole type definitions (`Points = [Point]`).
- [ ] Naming an element (`Todos[id]#t`).
