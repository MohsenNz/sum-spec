# SumSpec language server: plan

Notes for starting LSP development. Nothing here is built yet; the steps
are tracked in `TODO.md` under "Editor support".

## Goal

A language server, `sumspec lsp`, that gives Neovim (the main editor)
and VS Code what `sumspec check` gives on the command line, live while
editing: errors and warnings, navigation, highlighting and completion.
Editor support is one of the main reasons for the language, so the
server comes before any other editor tooling.

## Decisions

- **LSP first.** Highlighting comes from the server (semantic tokens),
  so it uses the real parser. A tree-sitter grammar is optional and
  comes later (see "Highlighting").
- **In this repository.** The server reuses `SumSpec.Parser` and
  `SumSpec.Check`, so it lives with them: a new module
  `src/SumSpec/Lsp.hs`, run as a subcommand of the existing executable,
  `sumspec lsp` (stdio). Editor setup files go in `editors/`.
- **The `lsp` package** (haskell/lsp, the library HLS is built on).
  Add it in `sumspec.cabal`, not in `flake.nix`. `lsp-test` for tests.
- **A tiny base grammar per editor** as a fallback, so a file is
  coloured before the server attaches or when it isn't running.

## What exists already

- `parseSpec :: FilePath -> Text -> Either ParseError Spec`.
- `checkSpec` returns every error and warning, sorted by position, with a
  severity (`sumspec check` exits 0 with only warnings).
- Every `Name` in the AST (`SumSpec.Syntax`) carries its source position.
- `SumSpec.Pretty` prints the canonical form.
- Golden test corpora in `test/parse` and `test/check`, and the example
  specs in `example/`.

## Groundwork in the Haskell code

Do these before (or while) writing the server. Each comes with golden
tests.

1. **Ranges.** LSP diagnostics and semantic tokens need a start and an
   end. A `Name`'s end follows from its text; a `CheckError` has one
   position today, so give it a range (or derive one from the token at
   its position). Parse errors need a range too.
2. **Parse recovery.** Megaparsec stops at the first parse error, so a
   file in the middle of an edit has no AST: no outline, no navigation,
   no checker errors until the syntax is fixed. Recover per definition
   with `withRecovery` and `registerParseError`: on an error, skip to the
   next definition boundary and go on. The grammar makes boundaries easy
   to find: a line starting `UPPER =`, `UPPER @` (a type with
   annotations), `lower ... ::` (an event) or `__init`. The result is
   every parse error plus a partial AST, which the checker should accept
   (checking only the definitions that parsed).
3. **A resolved model, `SumSpec.Model`.** Hover, go-to-definition on a
   path (`PMode.ShowMission.List`) and completion all need "what does
   this name refer to". The checker computes this internally today;
   exposing it also answers the open question in `TODO.md` ("Should the
   checker build a resolved model for code generators to consume?").
4. **Comments in the AST** (only for formatting, step 5 below).
   `Pretty` drops comments, so it can't reformat a real file yet.

## Features, in order

1. **Diagnostics**: parse and check on open and on change, publish
   errors (Error) and warnings (Warning). Usable on its own.
2. **Document symbols** (outline): types, constants, events, `__init`.
   **Go-to-definition and references** for type names, event names
   (`__events` entry to its transitions), annotations (a use to its line
   in `__annotations`), and constants.
3. **Semantic tokens**: type, variant, event, value name (`#x`, `x`),
   constant, annotation name and its opaque arguments, keywords (`__atomics`,
   `__init`, ...), context words (`by`, `not`, `and`, `or`, `in`),
   operators, literals, comments. The parser knows each role, which a
   regex grammar can't (a type vs a variant in a path, `by` as a word
   only inside `[T by K]`).
4. **Hover** (the definition of a type, the sum a variant belongs to, a
   constant's value, an annotation's declaration comment) and
   **completion**: type names after `::` and in patterns, variants after
   `.`, declared annotations after `@`, events in `__events`.
5. **Formatting** with `Pretty`, once the AST keeps comments.
6. Later: rename, code actions for checker suggestions (an element path
   for a list element, a missing `__events` entry), folding ranges.

## Highlighting

- **From the server**: semantic tokens (feature 3). Neovim (0.9+) and
  VS Code both lay them over their base highlighting.
- **Fallback, Neovim**: `editors/nvim/syntax/sumspec.vim`, a short Vim
  syntax file: comments, strings, numbers, `__` keywords and primitives,
  `@name`, UPPER and LOWER names, operators.
- **Fallback, VS Code**: a lexical TextMate grammar
  (`editors/vscode/syntaxes/sumspec.tmLanguage.json`) with the same
  tokens. It also serves Shiki, Sublime and GitHub (Linguist).
- **Optional later, tree-sitter**: folding, indentation, text objects,
  and Helix/Zed support. Keep it in `editors/tree-sitter-sumspec/`
  (nvim-treesitter can install from a subdirectory) and check it in CI:
  every file the Haskell parser accepts (`example/*`, valid
  `test/parse/*.sumspec`) must parse with no ERROR node. Annotation
  arguments up to the end of the line need care there (an external
  scanner if brackets must balance).

Every language change then also touches the fallback grammars (and
tree-sitter, if it exists); add them to the list in `CLAUDE.md` when they
are created.

## Editor setup (sketch)

Neovim (0.11+):

```lua
vim.filetype.add({ extension = { sumspec = "sumspec" } })

vim.lsp.config("sumspec", {
  cmd = { "sumspec", "lsp" },
  filetypes = { "sumspec" },
  root_markers = { ".git" },
})
vim.lsp.enable("sumspec")
```

VS Code: a minimal extension in `editors/vscode/` (`package.json`, the
TextMate grammar, a language configuration for comments and brackets,
and `vscode-languageclient` starting `sumspec lsp`). Its version and
release are its own, not `sumspec.cabal`'s.

## Testing

- Golden tests for recovery (a file with several broken definitions
  gives every parse error and checks the rest) and for ranges.
- `lsp-test` for the server: open a document, expect diagnostics; ask
  for a definition, symbols, semantic tokens.
- The example specs as smoke tests: no diagnostics but the expected
  warnings.

## Open

- The file extension: `.sumspec` (the test corpora use it; the example
  specs have none and need one for filetype detection).
- How annotation arguments up to the end of the line interact with
  recovery (a broken annotation should not swallow the next definition).
- Whether diagnostics run on every change or after a short delay, for
  large specs.
