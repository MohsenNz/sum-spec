# Changes

Every release of `sumspec`, newest first, with the language version it
implements. See `VERSIONING.md` for how versions are numbered.

## Unreleased

### Language

- Language version 1.1: transition inputs. A transition may take an
  input, written after its name (`toggleTodo TodoId :: ...`). Every
  signature of a transition takes the same input, or none. An input
  picks one list element by key. The input is a type pattern, so it
  can name its parts: `select Ref(Id#i * Name#n) :: ...`.
- Named values, also in 1.1: `P#x` names the value a pattern matches, in
  the input or on the source side, and `x` uses it. On the source side a
  name is an equality guard; on the target side it sets the value.
- `example/todomvc` uses inputs and named values.

### Tool

- The parser, printer and checker read transition inputs, and accept
  `__version 1.1`.
- The checker reports an input whose type is unknown, signatures of one
  transition with different inputs, and inputs in a spec that is 1.0.
- The parser and printer read named values; the checker reports unknown
  names, names given twice or on the target side, names of the wrong
  type, and names in a spec that is 1.0.

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
