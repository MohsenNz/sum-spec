# Changes

Every release of `sumspec`, newest first, with the language version it
implements. See `VERSIONING.md` for how versions are numbered.

## Unreleased

### Language

- Language version 1.1: transition inputs. A transition may take an
  input, written after its name (`toggleTodo TodoId :: ...`). Every
  signature of a transition takes the same input, or none. The input is
  a type pattern, so it can name its parts:
  `select Ref(Id#i * Name#n) :: ...`.
- Named values, also in 1.1: `P#x` names the value a pattern matches, in
  the input or on the source side, and `x` uses it. On the source side a
  name is an equality guard; on the target side it sets the value.
- A list element is picked by comparing its key with a named input:
  `toggleTodo TodoId#id :: Todo(id * ...)`.
- `example/todomvc` uses inputs and named values.
- Language version 1.2: element paths. `L[x]` is the element of the
  list type `L` whose key equals the named value `x`, written where `L`
  is expected, with the element's arguments after it:
  `Projects[p](Todos[t](Completion.Active))`. Paths nest, so an element
  of an outer list can be picked. An element takes no prime, and its
  arguments don't write the key.
- `example/todomvc` is 1.2: `deleteTodo` picks the todo with
  `Todos[id]`.

### Tool

- The parser, printer and checker read transition inputs, and accept
  `__version 1.1`.
- The checker reports an input whose type is unknown, signatures of one
  transition with different inputs, and inputs in a spec that is 1.0.
- Warnings: the checker reports parts of a valid spec that are less
  precise than they could be, marked `warning:`; `sumspec check` exits
  with 0 when there are only warnings. The first warning: a transition
  inside a list element that doesn't say which element it changes.
- `example/git` is 1.1: per-file transitions pick the file by `Path`.
- The parser and printer read named values; the checker reports unknown
  names, names given twice or on the target side, names of the wrong
  type, and names in a spec that is 1.0.
- The parser, printer and checker read element paths, and accept
  `__version 1.2`. The checker reports an element path on a type that
  isn't a named list, through a variant, with a key that isn't a factor
  of the element, with the key written in its arguments, primed, named
  or in the input, and in a spec older than 1.2.
- The warning about a transition inside a list element suggests an
  element path when the list has a type name (`Files[id](...)`), and
  nested paths for an element of an outer list.

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
