# Changes

Every release of `sumspec`, newest first, with the language version it
implements. See `VERSIONING.md` for how versions are numbered.

## Unreleased

Language version 1.0, still in development (see "Before the first
release" in `VERSIONING.md`).

### Language

- An event is defined once: its name and input, then all its
  transitions, each starting with `::`:
  `press :: A -> B`, then `:: C -> D` on the next line. Writing an
  event's name again is an error. The input is written once, and its
  names are visible in every transition.
- Initial state: `__init :: P` gives the state the app starts in, once
  per spec. Its head type is the root, the type of every state, so `App`
  is no longer required or special (`example/git` drops
  `App = Repository` for `__init :: Repository.Uninitialized`). `P` is a
  whole new state: no prime, name or element path in it.
- Events: the lowercase name before `::` is an event, listed in
  `__events` (was `__txs`); each `event :: source -> target` is one of
  its transitions. An event may have several transitions, and they share
  its input. Naming convention: imperative for commands (`toggleTodo`),
  past tense for occurrences (`linkLost`).
- The two sides of a transition are states of the same type: they're
  headed by the same type name (`Page.Home -> Page.Plan`, not
  `Page.Home -> Missions`).
- A prime doesn't go inside a new state (`Page -> Page.Plan(PMode')`):
  nothing there has an old value to change. Write `PMode`, which may
  have any value there, or leave it out.
- Event inputs: an event may take an input, written once after its
  name (`toggleTodo TodoId :: ...`). The input is a type pattern, so it
  can name its parts: `select Ref(Id#i * Name#n) :: ...`.
- Named values: `P#x` names the value a pattern matches, in the input or
  on the source side, and `x` uses it. On the source side a name is an
  equality guard; on the target side it sets the value.
- Keyed lists: `[T by K]` is a list whose elements are identified by a
  unique key of type `K`, which belongs to the list, not to the element:
  `Todos = [Todo by TodoId]`. Any type can be an element
  (`Files = [FileState by Path]`).
- Element paths: `L[x]` is the element of the keyed list type `L` whose
  key equals the named value `x`, written where `L` is expected, with
  the element's arguments after it:
  `Projects[p](Todos[t](Completion.Active))`. Paths nest, so an element
  of an outer list can be picked. An element that isn't a product takes
  one argument headed by its type (`Files[p](FileState.Staged)`). An
  element takes no prime.
- In a list without a key, an element is picked by comparing a key
  factor with a named input: `toggleTodo TodoId#id :: Todo(id * ...)`.
- A list goes only as the whole body of a type definition
  (`Points = [Point]`), so every list has a type name. A list isn't a
  factor, a payload or a pattern, and its element is a type name
  (`Row = [Cell]`, `Grid = [Row]`). A list type takes no arguments.
- The examples use these: `example/todomvc` and `example/git` have keyed
  lists (`Todos`, `Files`, `Branches`) and element paths, and
  `example/drone` names its lists (`Points`, `MissionSummaries`).

### Tool

- The parser, printer and checker read event inputs, named values,
  keyed lists, element paths and `__init`.
- Warnings for a variant the app never reaches from `__init`, and for
  two transitions of one event, on the same type, whose sources can
  match the same state (`example/todomvc` warns about `deleteTodo` and
  `clearCompleted`, and `example/git` about `merge` and
  `rebaseContinue`). `example/drone` gains `selectMission`,
  `editMission`, `startFlight`, `takeOff`, `flightFailed`, `landed` and
  `dismissFailure`, so every variant is reached; its `PMode.Flight`
  now carries `Flight`.
- The checker reports a missing or repeated `__init` (in place of the
  missing `App`), and a prime, naming, name or element path in it. The
  warnings about list elements walk from the root.
- `sumspec check` warns about a space before a prime or a naming
  (`A '`, `Text #t`).
- The checker reports:
  - an input whose type is unknown, and an event defined twice;
  - unknown names, names given twice or on the target side, and names
    of the wrong type;
  - an unknown key type;
  - for element paths: a type that isn't a list, a list without a key,
    a path through a variant (suggesting `Ring.Points(Points[i])`), a
    key of the wrong type, arguments that don't fit the element, a
    prime, a naming, and a path in the input;
  - a list written anywhere but as a whole type definition, and
    arguments after a list type.
- Warnings: the checker reports parts of a valid spec that are less
  precise than they could be, marked `warning:`; `sumspec check` exits
  with 0 when there are only warnings. The first warning: a transition
  inside a list element that doesn't say which element it changes. It
  suggests an element path (`Files[id](...)`), and a key for a named
  list that has none.

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
