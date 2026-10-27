# TODO

## Done

### Language spec (`spec/`)
- [x] Settle the v1 semantics in `spec-v1.md`: products keyed by type,
      newtypes, a variant namespace per sum, inline payloads and paths,
      a sum without a variant means any variant, naming rules, comments.
- [x] Move variant refinement and partial product patterns to
      `proposals.md`.
- [x] Write the v1 grammar: `grammar.ebnf`, with `--` line comments.
- [x] Make `spec/example` (renamed from `spec/syntax`) follow v1:
      `Point` and `Settings` are atomics, refinements are inlined, every
      product pattern lists all of its factors.

### Project setup
- [x] `CLAUDE.md`.
- [x] Cabal project `sumspec` (library, `sumspec` CLI, test suite),
      built inside `nix develop`, formatted with the project's
      `fourmolu.yaml`.

### Parser
- [x] AST: `src/SumSpec/Syntax.hs`.
- [x] Lexer and parser (megaparsec): `src/SumSpec/Lexer.hs`,
      `src/SumSpec/Parser.hs`.
- [x] Printer to canonical source: `src/SumSpec/Pretty.hs`.
- [x] CLI: `sumspec parse FILE`.
- [x] Golden tests: `test/parse/` (valid and `error-*` cases, plus
      `spec/example`), each also checked by a print-and-parse round trip.

## Remaining

### Type checker
The rules are listed in the notes at the end of `spec/grammar.ebnf`.

- [ ] Decide the checker's error type and message format (with
      positions, like parse errors), and whether it reports every error
      or stops at the first.
- [ ] Decide whether the checker builds a resolved model of the spec
      (e.g. `SumSpec.Model`) or only validates the AST.
- [ ] Names:
  - [ ] `App` is defined.
  - [ ] Every type name used is an atomic or a defined type.
  - [ ] No type is both atomic and defined, and none is defined twice.
  - [ ] No name is listed twice in `__atomics` or `__txs`.
  - [ ] Every transition is listed in `__txs`, and every name in
        `__txs` has at least one signature.
- [ ] Type definitions:
  - [ ] Variant names are unique within one sum.
  - [ ] Type names are unique within one product (`T = A * A`).
- [ ] Patterns:
  - [ ] Every path leads through real variants (`Page.Plan`,
        `PMode.ShowMission.List`).
  - [ ] Arguments match the payload or product: factors matched by type
        name in any order, every factor written.
  - [ ] A sum written without a variant means any of its variants.
- [ ] Golden tests for the checker: valid cases and one invalid case per
      rule.
- [ ] CLI: `sumspec check FILE`.

### Open questions
- [ ] Can a pattern look through a newtype (e.g. `Boundary(Ring.Enclosed)`
      where `Boundary = Ring`)? `proposals.md` uses this form.
- [ ] Optional warnings: states no transition reaches, and transitions
      whose signatures overlap.

### Housekeeping
- [ ] Commit the parser work.
- [ ] Run `cabal update` (the Hackage package list is a year old).
- [ ] README: how to build and use the `sumspec` CLI.

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
