# TODO

## Remaining

### Open questions
- [ ] Optional warnings: states no transition reaches, and transitions
      whose signatures overlap.
- [ ] Should the checker build a resolved model of the spec (e.g.
      `SumSpec.Model`) for code generators to consume?

### Versioning
- [x] Versioning policy (`VERSIONING.md`) and `CHANGES.md`; proposals
      marked additive or breaking.
- [ ] Release 0.1.0.0: date it in `CHANGES.md`, then tag `v0.1.0.0`.
- [ ] Before the first language change after 1.0: a `__version` header
      in spec files (e.g. `__version 1.1`, none meaning 1.0), so the
      checker and agents know which rules apply.

### Housekeeping
- [ ] Commit the type checker work.
- [ ] Run `cabal update` (the Hackage package list is a year old).
- [x] README: how to build and use the `sumspec` CLI.

### Later (`spec/proposals.md`)
Not part of v1. Each one changes the semantics, so it needs a spec
update before any code:
- [ ] Several transitions with one signature (`g, h :: Y -> Z`).
- [ ] Transition inputs (`f X :: A -> B`).
- [ ] Post-transition values (`A'`).
- [ ] `=>` (shared construction path) and `<-` shorthand.
- [ ] Annotations (`__annotations`).
- [ ] Dependent types and generic types.
- [ ] Variant refinement (`PMode.ShowMission = ...`).
- [ ] Partial product patterns (an omitted part means "unchanged").
