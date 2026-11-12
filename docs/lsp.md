# SumSpec language server: plan

Notes for LSP development; the steps are tracked in `TODO.md` under
"Editor support". Built so far: parse recovery, diagnostics, the
outline, go to definition, references, semantic tokens, hover and
completion (features 1 to 4), the resolved model, and the Neovim plugin. See "What's built" below. Until errors
carry ranges, a diagnostic's range is the token at its position
(`tokenRange` in `lsp/SumSpec/Lsp/Position.hs`).

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
- **In this repository, outside the core library.** The server reuses
  `SumSpec.Parser` and `SumSpec.Check`, so it lives with them, in the
  same cabal package: an internal library `sumspec-lsp`
  (`lsp/SumSpec/Lsp.hs`), so the core library keeps its few
  dependencies. It runs as a subcommand of the existing executable,
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

## What's built

The server (`lsp/SumSpec/Lsp.hs`) parses the document from the editor's
copy on each request, with no cache, using `parseSpecPartial`. Its pure
parts are modules of their own in `lsp/SumSpec/Lsp/`.

### Recovery

`parseSpecPartial` (`src/SumSpec/Parser.hs`) reads the definitions one
at a time. When one doesn't parse, it records the error and skips to the
next line whose first character, in column 1, is neither a space nor the
start of a `--` comment, then reads on. Every example starts its
definitions in column 1 and indents the lines that continue them. It
skips at least a line, unless the error is at the start of a line past
the definition's start, which may be the next definition.

- An error at the very start of a definition is reported with the hints
  of the definition before it (what could have continued it), as if
  nothing had been recovered: the parser parses that definition again
  to get them.
- An error in the version header or the header blocks stops the parse;
  the server then answers requests with nothing.
- An annotation's arguments may span lines inside brackets, so a bracket
  left open runs on to the end of the file. It is reported at the
  outermost open bracket, and recovery goes on from the line after the
  annotation, so the next definition is not lost.
- A parser error at another offset than the current one goes through
  `failAt` (`src/SumSpec/Lexer.hs`), never `setOffset`: that would put
  the offset out of step with the input, and shift every position
  after the recovery.

While a document has parse errors, the server shows every parse error
and no checker diagnostics; the partial AST still feeds the outline,
navigation and highlighting.

### The index (`lsp/SumSpec/Lsp/Index.hs`)

Every name in the spec, with its kind (type, variant, event, annotation,
constant, value), whether it is the definition, and its target (the
defining name), or none when it doesn't resolve. Definitions are the
atomics, type definitions, variants (inline payloads included), event
definitions, `__annotations` entries, constants and `#x`. An
`__events` entry is a use of the event's definition.

Paths are resolved left to right. The head is a type, a constant when
it names one, or else the one variant with that name in the spec. Each
later name is:

1. a variant of the sum the path is at; else
2. a type of that name; else
3. the one variant with that name in the spec.

After a variant, the path is at its payload: a named type, or an inline
sum (`Landed (Spot | Field)`). A newtype (`T = A`) is followed to the
type it names, a few steps at most. The alternatives of `S.{A | B}` are
resolved from where `S` is; their arguments are paths of their own.

A value is scoped to one transition: the input's `#x` and the source's
bind it; a use (in the source, the guard, the target, an element key
`L[x]` or a shared path's key) points at the first binding with the
same text.

### The model (`src/SumSpec/Model.hs`)

`model :: Spec -> Model`, in the core library: every type with its
shape (atomic, sum, product, newtype, list), every variant with the sum
it belongs to (`Mode.Flying.Landed` for one in an inline payload), the
constants, the events (and whether `__events` lists them), the declared
annotations and the root type. A name defined twice keeps its first
definition. `resolvePath` and `resolveFrom` resolve paths by the rule
under "The index" below; `variantsAt` gives the variants of the sum a
path is at, through newtypes. The index, hover and completion read the
spec through it, and the checker builds its `Env` from it (its own path
resolution, with its errors, is separate). `renderModel` prints it for
the golden corpus `test/model/`.

### Hover (`lsp/SumSpec/Lsp/Hover.hs`)

Markdown with a `sumspec` code block: a type's definition (printed by
`Pretty`), a variant's path and the sum it belongs to, a constant's
definition, an event's input and its number of transitions (and whether
`__events` lists it), an annotation, a value's type (`T` of `T#x`).
Then the comments about the definition, read from the source since the
AST has none: the comment lines just above it at its indentation, and
the comment after it on its line with the comment lines under that one
at the same column. An event also gets the comment beside its
`__events` entry.

### Completion (`lsp/SumSpec/Lsp/Completion.hs`)

The line being typed seldom parses, so the context is the text before
the cursor, and the names come from the model of what parses:

- in a comment or a string: nothing;
- inside `__events { }`: the events defined but not listed; inside the
  other header blocks, nothing;
- after `@`: the declared annotations, with their comments;
- after `Path.`: the variants of the sum the path is at (through
  newtypes), or the factors of a product;
- at the start of a line: `__init`, `__annotations`, and the events
  listed but not yet defined;
- elsewhere: every type and constant, and the `#x` names written so far
  in the definition being typed (read from its text).

Trigger characters are `.` and `@`; the editor filters by the prefix.

### Semantic tokens (`lsp/SumSpec/Lsp/Tokens.hs`)

A lexical scan finds comments, strings, numbers, `__` words, operators,
`@name` and names. A name takes its kind from the index: `type`,
`enumMember` (a variant), `event`, `variable` (a value, or a constant
with `readonly`), `decorator` (an annotation), with `declaration` on a
definition. An unclaimed `by`, `not`, `and`, `or` or `in` is a keyword;
any other unclaimed name gets no token, so the editor's syntax file
colours it. Annotation arguments are opaque and get no tokens but
strings and numbers. The legend is LSP's standard one.

## Groundwork in the Haskell code

Do these before (or while) writing the server. Each comes with golden
tests.

1. **Ranges.** LSP diagnostics and semantic tokens need a start and an
   end. A `Name`'s end follows from its text; a `CheckError` has one
   position today, so give it a range (or derive one from the token at
   its position). Parse errors need a range too. Names are done:
   `nameRange` (`lsp/SumSpec/Lsp/Position.hs`) gives a name's range from
   its text, which navigation and semantic tokens use; errors are not.
2. **Parse recovery.** Done; see "Recovery" above. Still open: the
   checker should accept the partial AST, checking only the definitions
   that parsed without errors about the names they define.
3. **A resolved model, `SumSpec.Model`.** Done; see "The model" above.
   Still open: the checker's own path resolution could move onto it.
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
- **Fallback, Neovim**: `syntax/sumspec.vim` in the
  [sumspec.nvim](https://github.com/MohsenNz/sumspec.nvim) plugin, a
  short Vim syntax file: comments, strings, numbers, `__` keywords and
  primitives, `@name`, `#name`, names, operators. It spell-checks
  comments only. The plugin's ftplugin links the semantic token groups
  (`@lsp.type.<type>.sumspec`) to the usual tree-sitter groups.
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
tree-sitter, if it exists); `CLAUDE.md` lists them.

## Editor setup (sketch)

Neovim (0.11+): the plugin
[sumspec.nvim](https://github.com/MohsenNz/sumspec.nvim), a repository
of its own so that plugin managers can install it. It ships
`lsp/sumspec.lua`, which Neovim reads as the server's configuration, so
the user's config is only:

```lua
vim.lsp.enable("sumspec")
```

VS Code: a minimal extension in `editors/vscode/` (`package.json`, the
TextMate grammar, a language configuration for comments and brackets,
and `vscode-languageclient` starting `sumspec lsp`). Its version and
release are its own, not `sumspec.cabal`'s.

## Testing

- Golden tests for recovery (a file with several broken definitions
  gives every parse error and checks the rest) and for ranges.
- `lsp-test` for the server (`test/lsp/Main.hs`, the test suite
  `sumspec-lsp-test`, which runs the server inside the test process, over
  pipes): open a document, expect diagnostics; ask for a definition,
  symbols, semantic tokens.
- The example specs as smoke tests: no diagnostics but the expected
  warnings.

## Open

- Whether diagnostics run on every change or after a short delay, for
  large specs.
