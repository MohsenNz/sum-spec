# SumSpec

SumSpec is a language for writing an application's spec as types (sums and
products) and state transitions. AI agents read a SumSpec file to generate
the application. This repo holds the language spec and its implementation
in Haskell: a parser first, then a type checker.

`TODO.md` tracks what's done and what remains. Tick items off and add new
ones as the work changes.

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
the notes at the end of `grammar.ebnf`; the pattern rules are in
`spec-v1.md` ("Arguments in state patterns").

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
nix develop -c cabal run sumspec -- parse <file>
nix develop -c cabal run sumspec -- check <file>
nix develop -c fourmolu -i src app test
```

The shellHook sources `.env`, which holds local proxy settings. It's
git-ignored (template: `.env.example`); never commit it.

Add Haskell dependencies in the `.cabal` file, not in `flake.nix`, unless
they need system libraries.

## Project layout

One cabal package, `sumspec` (`sumspec.cabal`, `cabal.project`):

- `src/SumSpec/Syntax.hs`: the AST. Every `Name` carries its source
  position.
- `src/SumSpec/Lexer.hs`: tokens, whitespace and `--` comments.
- `src/SumSpec/Parser.hs`: one parser per rule in `grammar.ebnf`, named
  after the rule.
- `src/SumSpec/Pretty.hs`: prints an AST back as canonical SumSpec source.
- `src/SumSpec/Check.hs`: the type checker. It validates the AST and
  returns every error, sorted by position.
- `src/SumSpec.hs`: re-exports the public modules.
- `app/Main.hs`: the `sumspec` command-line tool. `sumspec parse FILE`
  prints the canonical form or the parse error; `sumspec check FILE`
  prints nothing for a valid spec, or every error (exit code 1).
- `test/Main.hs`: the golden test runner; `test/parse/` and
  `test/check/`: the corpora.

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

Tests run against two corpora of small spec files. Each `foo.sumspec`
has a `foo.golden` next to it holding the expected output. Invalid files
are named `error-*.sumspec`. `spec/example` is a case in both, with its
golden file `spec-example.golden` in each directory.

- `test/parse/`: the golden file is the canonical form, or the parse
  error. Each file is checked twice: once as parsed, and once after
  printing and parsing again (round trip), against the same golden file.
- `test/check/`: the golden file is `OK`, or the type errors.

To add or update cases, run `nix develop -c cabal test
--test-options=--accept`, then read every new or changed golden file
before keeping it; accepting only proves the output is stable, not
correct. When the grammar or a checker rule changes, add a test case for
it.
