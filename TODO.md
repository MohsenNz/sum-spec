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
- [ ] Guards on data.
- [x] How updates change values, Part A: named values.
- [ ] How updates change values, Part B: derived values.
- [ ] How updates change values, Part C: list updates (form chosen:
      an action clause, `// __remove ts[id]`).
- [ ] Nondeterminism between transitions: first match, once guards
      exist (see gap 5).
- [ ] Values inside a new state.

### Versioning
- [ ] Release 0.1.0.0: date it in `CHANGES.md`, then tag `v0.1.0.0`.

### Later (`spec/proposals.md`)
Not part of v1. Each one changes the semantics, so it needs a spec
update before any code:
- [x] `=>` (shared construction path).
- [ ] Naming an element (`Todos[id]#t`).
- [ ] Annotations (`__annotations`), also on transitions.
- [ ] Dependent types and generic types.
- [ ] Variant refinement (`PMode.ShowMission = ...`).
- [ ] Several events with one transition (`g, h :: Y -> Z`).
- [ ] `<-` shorthand.
