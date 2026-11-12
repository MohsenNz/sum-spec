# SumSpec

SumSpec is a language for writing an application's spec as types (sums and
products) and state transitions. AI agents read a SumSpec file to generate
the application. This repo holds the language spec and its implementation
in Haskell: a parser first, then a type checker.

`TODO.md` tracks what's done and what remains. Tick items off and add new
ones as the work changes.

## Source of truth: `spec/` and `example/`

- `spec/spec-v1.md`: the language definition.
- `spec/grammar.ebnf`: the v1 grammar (ISO EBNF). It's frozen for the
  implementation; don't change it without being asked.
- Example specs, in `example/` at the project root. Each must parse and
  type-check with no errors:
  - `example/drone.sumspec`: the reference example (a drone mission planner app).
  - `example/todomvc.sumspec`: a UI, TodoMVC.
  - `example/git.sumspec`: an application core, a local Git repository.
- `spec/proposals.md`: future features that are **not** in v1. Don't
  implement them unless asked. Each says whether it's additive or
  breaking.

A language change touches `spec-v1.md`, `grammar.ebnf` and the example
specs together; keep them in sync. A change to the language's words or
operators also touches `syntax/sumspec.vim` in the `sumspec.nvim`
repository. The type checker's rules are listed in
the notes at the end of `grammar.ebnf`; the pattern rules are in
`spec-v1.md` ("Arguments in state patterns").

## Versioning

See `VERSIONING.md`. In short:

- Until the first release, the language is 1.0 in development: every
  change, breaking or not, goes straight into 1.0, with no version
  checks, "Added in" notes or warnings for old forms. The rules below
  apply from the first release.
- The language version is `major.minor` (currently 1.0). A breaking
  change raises the major version and starts `spec-v<major>.md`; an
  additive change raises the minor version and goes into the current
  `spec-v<major>.md` with an "Added in 1.x" line under its heading.
- The language version is independent of the tool version in
  `sumspec.cabal`.
- Record every user-visible change under **Unreleased** in `CHANGES.md`,
  marked as language or tool.
- Don't change `version:` in `sumspec.cabal` or create tags unless asked;
  that happens at release time.

## Development environment

Run every tool inside the Nix flake (GHC 9.10.3, cabal, HLS, fourmolu):

```
nix develop -c cabal build all
nix develop -c cabal test
nix develop -c cabal run sumspec -- parse <file>
nix develop -c cabal run sumspec -- check <file>
nix develop -c fourmolu -i src app lsp test
```

The shellHook sources `.env`, which holds local proxy settings. It's
git-ignored (template: `.env.example`); never commit it.

Add Haskell dependencies in the `.cabal` file, not in `flake.nix`, unless
they need system libraries.

## Project layout

One cabal package, `sumspec` (`sumspec.cabal`, `cabal.project`), with
the core library (`src/`), an internal library `sumspec-lsp` (`lsp/`),
the executable (`app/`) and two test suites:

- `src/SumSpec/Syntax.hs`: the AST. Every `Name` carries its source
  position.
- `src/SumSpec/Lexer.hs`: tokens, whitespace and `--` comments.
- `src/SumSpec/Parser.hs`: one parser per rule in `grammar.ebnf`, named
  after the rule.
- `src/SumSpec/Pretty.hs`: prints an AST back as canonical SumSpec source.
- `src/SumSpec/Version.hs`: language versions and the newest one this
  sumspec implements (`latestVersion`).
- `src/SumSpec/Model.hs`: the resolved model of a spec (types, variants
  and their sums, constants, events, annotations) and path resolution.
  Lenient: it works on partial specs. The language server reads specs
  through it; the checker builds its environment from it.
- `src/SumSpec/Check.hs`: the type checker. It validates the AST and
  returns every error, sorted by position.
- `src/SumSpec.hs`: re-exports the public modules.
- `app/Main.hs`: the `sumspec` command-line tool. `sumspec parse FILE`
  prints the canonical form or the parse error; `sumspec check FILE`
  prints nothing for a valid spec, or every error (exit code 1) and
  warning (exit code 0 if there are only warnings). `sumspec lsp` runs
  the language server.
- `lsp/SumSpec/Lsp.hs`: the language server (the `lsp` package): its
  handlers. Keep `lsp` and its dependencies out of the core library.
  - `lsp/SumSpec/Lsp/Position.hs`: source positions to LSP positions
    and ranges (UTF-16, tabs).
  - `lsp/SumSpec/Lsp/Index.hs`: every name in a spec, what it names and
    where that's defined; the outline.
  - `lsp/SumSpec/Lsp/Tokens.hs`: semantic tokens.
  - `lsp/SumSpec/Lsp/Hover.hs`: hover, and the comments beside a
    definition.
  - `lsp/SumSpec/Lsp/Completion.hs`: completion, from the text before
    the cursor.
- `test/Main.hs`: the golden test runner; `test/parse/`, `test/check/`
  and `test/model/`: the corpora.
- `test/lsp/Main.hs`: the language server tests (`lsp-test`).
- `editors/`: editor setup. The Neovim plugin, with the Vim syntax file,
  is a separate repository, `sumspec.nvim` (locally `../sumspec.nvim`).

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

Tests run against three corpora of small spec files. Each `foo.sumspec`
has a `foo.golden` next to it holding the expected output. Invalid files
are named `error-*.sumspec`. The example specs are cases in each, listed
in `examples` in `test/Main.hs`, with golden files named
`example-<name>.golden` in each directory.

- `test/parse/`: the golden file is the canonical form, or the parse
  error. Each file is checked twice: once as parsed, and once after
  printing and parsing again (round trip), against the same golden file.
- `test/check/`: the golden file is `OK`, or the type errors.
- `test/model/`: the golden file is the resolved model (`renderModel`)
  of the definitions that parse.

To add or update cases, run `nix develop -c cabal test
--test-options=--accept`, then read every new or changed golden file
before keeping it; accepting only proves the output is stable, not
correct. When the grammar or a checker rule changes, add a test case for
it.
