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
cabal run sumspec -- check example/drone.sumspec
```

To install `sumspec` on your `PATH`, use the flake's package:

```
nix profile add .           # install
nix profile upgrade sum-spec  # update after changes (see `nix profile list` for the name)
nix run . -- check FILE     # or run it without installing
```

Nix takes the dependencies prebuilt from the binary cache and compiles
only `sumspec`, without running the tests. It builds the files git
tracks, so `git add` new files first.

`cabal install exe:sumspec` works too, but run it inside `nix develop`.
Cabal keeps one package store per GHC build, and the flake's GHC is the
one that already has the dependencies built; with another GHC (one from
`~/.nix-profile`, say), cabal compiles every dependency, `lsp` and
`lens` among them, from scratch.

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

### `sumspec lsp`

Runs the language server on stdin and stdout, for an editor to start. It
shows the parse error, or every error and warning of the checker, as you
edit. See `editors/nvim/README.md` for Neovim.

## Running the tests

```
cabal test
```

The tests are golden tests over two corpora of small specs:
`test/parse/` (the canonical form or the parse error) and `test/check/`
(`OK` or the type errors). The example specs are cases in both. To add
or update cases, run `cabal test --test-options=--accept`, then read
every new or changed golden file before keeping it.

The language server has its own suite, `cabal test sumspec-lsp-test`,
which drives the server with `lsp-test`.

Format the code with fourmolu before committing:

```
fourmolu -i src app lsp test
```

## Project layout

- `src/SumSpec/Syntax.hs`: the AST.
- `src/SumSpec/Lexer.hs`, `src/SumSpec/Parser.hs`: tokens, and one
  parser per rule in `spec/grammar.ebnf`.
- `src/SumSpec/Pretty.hs`: prints an AST back as canonical source.
- `src/SumSpec/Check.hs`: the type checker.
- `lsp/SumSpec/Lsp.hs`: the language server, an internal library.
- `app/Main.hs`: the `sumspec` command-line tool.
- `test/Main.hs`: the golden test runner.
- `test/lsp/Main.hs`: the language server tests.
- `editors/`: editor setup.

## More

- `TODO.md`: what's done and what remains.
- `CHANGES.md`: every user-visible change, under **Unreleased**.
- `VERSIONING.md`: the language version and the tool version.
- `docs/lsp.md`: the plan for the language server.
- `docs/sumspec-vs-quint-tla.md`: how SumSpec relates to Quint and TLA+.
