# TODO

## Done

### Language spec (`spec/`)
- [x] Settle the v1 semantics in `spec-v1.md`: products keyed by type,
      newtypes, a variant namespace per sum, inline payloads and paths,
      a sum without a variant means any variant, naming rules, comments.
- [x] Move variant refinement and partial product patterns to
      `proposals.md`.
- [x] Write the v1 grammar: `grammar.ebnf`, with `--` line comments.
- [x] Make `example/drone` (was `spec/syntax`) follow v1:
      `Point` and `Settings` are atomics, refinements are inlined, every
      product pattern lists all of its factors.
- [x] Two more example specs, both tested: `example/todomvc` (a UI)
      and `example/git` (an application core).

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
      the example specs), each also checked by a print-and-parse round trip.

### Type checker
- [x] `src/SumSpec/Check.hs`: validates the AST (no separate model) and
      reports every error, sorted by position, in the same format as
      parse errors.
- [x] Names: `App` is defined; every type used is known; no type both
      atomic and defined, or defined twice; no name listed twice in
      `__atomics` or `__txs`; every transition listed in `__txs`, and
      every listed name has a signature.
- [x] Type definitions: unique variants per sum, unique factors per
      product, no newtype cycles.
- [x] Patterns: paths go only into sums; arguments fit what they follow
      (rules in `spec-v1.md`, "Arguments in state patterns"); no
      arguments means any value; the two sides may be different types.
- [x] Golden tests: `test/check/` (valid cases, the `spec-v1.md`
      examples, the example specs, and `error-*` cases for every rule).
- [x] CLI: `sumspec check FILE`.
- [x] Checker rules listed in the notes of `spec/grammar.ebnf`.

## Remaining

### Open questions
- [ ] Optional warnings: states no transition reaches, and transitions
      whose signatures overlap.
- [ ] Should the checker build a resolved model of the spec (e.g.
      `SumSpec.Model`) for code generators to consume?

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
