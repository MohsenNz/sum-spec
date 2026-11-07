# Development

How to build, run and test `sumspec`, the parser and type checker for
SumSpec, written in Haskell.

## Development environment

Every tool runs inside the Nix flake (GHC, cabal, HLS, fourmolu):

```
nix develop
```

The shell sources `.env` for local settings such as a proxy. It's
git-ignored; copy `.env.example` to start one.

## Using the `sumspec` CLI

Inside `nix develop`, build and run the CLI with cabal:

```
cabal run sumspec -- check example/drone
```

To install `sumspec` instead, into cabal's `installdir` (`~/.local/bin` by
default; make sure it's on your `PATH`):

```
cabal install exe:sumspec
```

### `sumspec check FILE`

Parses the spec and type-checks it. A valid spec prints nothing and exits
with code 0. Otherwise every error is printed to stderr, sorted by
position, and the exit code is 1.

Warnings point at parts of a valid spec that are less precise than they
could be, such as a transition inside a list element that doesn't say
which element it changes. They are printed like errors, marked
`warning:`, and a spec with only warnings exits with code 0:

```
$ sumspec check test/check/error-bad-path.sumspec
test/check/error-bad-path.sumspec:10:20:
   |
10 | notVariant :: Page.Nope -> Page.Home
   |                    ^
Nope is not a variant of Page
...
```

### `sumspec parse FILE`

Parses the spec without type-checking it, and prints it back in a
canonical layout: one definition per line, with comments removed. A
parse error is printed to stderr with exit code 1.

```
$ sumspec parse test/parse/v1-initial-state.sumspec
...
__init :: Z(Y.V1)
Z = Y * C
Y = V1 | V2 | V3 A
trans1 :: Y.V1 -> Y.V3(A)
trans2 :: Z(Y.V1 * C) -> Z(Y.V2 * C)
```

## Running the tests

```
cabal test
```

The tests are golden tests over two corpora of small specs:
`test/parse/` (the canonical form or the parse error) and `test/check/`
(`OK` or the type errors). The example specs are cases in both. To add
or update cases, run `cabal test --test-options=--accept`, then read
every new or changed golden file before keeping it.

Format the code with fourmolu before committing:

```
fourmolu -i src app test
```

## Project layout

- `src/SumSpec/Syntax.hs`: the AST.
- `src/SumSpec/Lexer.hs`, `src/SumSpec/Parser.hs`: tokens, and one
  parser per rule in `spec/grammar.ebnf`.
- `src/SumSpec/Pretty.hs`: prints an AST back as canonical source.
- `src/SumSpec/Check.hs`: the type checker.
- `app/Main.hs`: the `sumspec` command-line tool.
- `test/Main.hs`: the golden test runner.

## More

- `TODO.md`: what's done and what remains.
- `CHANGES.md`: every user-visible change, under **Unreleased**.
- `VERSIONING.md`: the language version and the tool version.
- `docs/lsp.md`: the plan for the language server.
