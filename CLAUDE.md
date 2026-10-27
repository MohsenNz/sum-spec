# SumSpec

SumSpec is a language for writing an application's spec as types (sums and
products) and state transitions. AI agents read a SumSpec file to generate
the application. This repo holds the language spec and its implementation
in Haskell: a parser first, then a type checker.

## Source of truth: `spec/`

- `spec/spec-v1.md`: the language definition.
- `spec/grammar.ebnf`: the v1 grammar (ISO EBNF). It's frozen for the
  implementation; don't change it without being asked.
- `spec/example`: the reference example spec. It must parse and type-check
  with no errors.
- `spec/proposals.md`: future features that are **not** in v1. Don't
  implement them unless asked.

A language change touches `spec-v1.md`, `grammar.ebnf` and `example`
together; keep the three in sync. The type checker's rules are listed in
the notes at the end of `grammar.ebnf`.

## Key v1 decisions

- Whitespace and newlines carry no meaning; `--` starts a line comment.
- Types and variants are uppercase; transitions are lowercase.
- A sum has at least two variants, so `T = A` is a newtype. A product has
  at least two factors.
- Products are keyed by type name: a type appears at most once, factor
  order doesn't matter, and a newtype is never equal to its base (`At = Timestamp`).
- Each sum has its own variant namespace (`Ring.Partial` and
  `Path.Partial` are different).
- In a state pattern, a sum without a chosen variant means any variant,
  and every product factor has to be written.
- An UPPER followed by `=` always starts a new type definition. This is
  the one place the parser needs two tokens of lookahead.

## Development environment

Run every tool inside the Nix flake (GHC 9.10.3, cabal, HLS, fourmolu):

```
nix develop -c cabal build all
nix develop -c cabal test
nix develop -c cabal run sumspec -- <args>
nix develop -c fourmolu -i src app test
```

The shellHook sources `.env`, which holds local proxy settings. It's
git-ignored (template: `.env.example`); never commit it.

Add Haskell dependencies in the `.cabal` file, not in `flake.nix`, unless
they need system libraries.

## Project layout

One cabal package, `sumspec` (`sumspec.cabal`, `cabal.project`):

- `src/`: the library (`SumSpec.*` modules).
- `app/Main.hs`: the `sumspec` command-line tool.
- `test/Main.hs`: the test suite (tasty + tasty-golden).

Libraries: megaparsec for parsing, text for source text, containers for
maps and sets.

## Haskell conventions

- Format with fourmolu using the project's `fourmolu.yaml` (2-space
  indent, 85 columns); don't override it. Build with `-Wall` and no
  warnings.
- The language is GHC2024 (set in the `common` stanza of the `.cabal` file).
- Keep lexing, parsing and type checking in separate modules. The AST is
  the interface between the parser and the checker.
- Errors carry source positions (line and column).

## Testing

Tests run against a corpus of small spec files. Each file is marked valid,
or invalid with the error it should produce, kept as a golden file
(tasty-golden). `spec/example` and the
examples in `spec/spec-v1.md` are valid cases. When the grammar or a
checker rule changes, add a test case for it.
