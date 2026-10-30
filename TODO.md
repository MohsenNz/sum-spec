# TODO

## Remaining

### Open questions
- [ ] Optional warnings: states no transition reaches, and transitions
      whose signatures overlap.
- [ ] Should the checker build a resolved model of the spec (e.g.
      `SumSpec.Model`) for code generators to consume?

### Closer to an EFSM (`spec/efsm-gaps.md`)
Decide on each gap, one at a time, then move it to `proposals.md`:
- [ ] Where a local transition applies (decided in part; waits for
      derived values in "How updates change values").
- [ ] Guards on data.
- [ ] How updates change values.
- [ ] Event inputs and outputs.
- [ ] Nondeterminism between signatures.
- [ ] Initial state.
- [ ] Values inside a new state.

### Versioning
- [x] Versioning policy (`VERSIONING.md`) and `CHANGES.md`; proposals
      marked additive or breaking.
- [ ] Release 0.1.0.0: date it in `CHANGES.md`, then tag `v0.1.0.0`.
- [x] `__version major.minor` header in spec files (part of 1.0; no
      header means 1.0). The parser rejects versions it doesn't
      implement.

### Housekeeping
- [ ] Commit the type checker work.
- [ ] Run `cabal update` (the Hackage package list is a year old).
- [x] README: how to build and use the `sumspec` CLI.

### Later (`spec/proposals.md`)
Not part of v1. Each one changes the semantics, so it needs a spec
update before any code:
- [ ] Several transitions with one signature (`g, h :: Y -> Z`).
- [ ] Transition inputs (`f X :: A -> B`).
- [ ] `=>` (shared construction path) and `<-` shorthand.
- [ ] Annotations (`__annotations`).
- [ ] Dependent types and generic types.
- [ ] Variant refinement (`PMode.ShowMission = ...`).
