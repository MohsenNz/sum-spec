# Changes

Every release of `sumspec`, newest first, with the language version it
implements. See `VERSIONING.md` for how versions are numbered.

## Unreleased

Nothing yet.

## 0.1.0.0 (not released yet)

Language version 1.0.

### Language

- First definition of the language, version 1.0, in `spec/spec-v1.md` and
  `spec/grammar.ebnf`:
  - type definitions: sums, products, newtypes and lists, with inline
    payloads nested to any depth;
  - transitions, with several signatures per transition;
  - state patterns: paths into sums, arguments, and partial products
    (factors may be left out);
  - source and target: on the source side a left-out part may have any
    value; on the target side a left-out or unprimed part keeps its
    value, a primed part (`A'`) gets a new value, and a part whose
    variant changes is a new state;
  - the `__atomics` and `__txs` headers, the `App` entry point, and
    `--` line comments;
  - the optional `__version 1.0` header; no header means 1.0.
- Example specs: `example/drone`, `example/todomvc`, `example/git`.

### Tool

- Parser with error messages that show the line and column.
- Type checker that reports every error, sorted by position.
- CLI: `sumspec parse FILE` and `sumspec check FILE`.
- Golden tests for the parser and the checker.
