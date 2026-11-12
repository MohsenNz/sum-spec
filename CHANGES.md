# Changes

Every release of `sumspec`, newest first, with the language version it
implements. See `VERSIONING.md` for how versions are numbered.

## Unreleased

Language version 1.0, still in development (see "Before the first
release" in `VERSIONING.md`).

### Language

- Computed values in targets: a target may set a value computed from the
  names the transition gives, literals and named constants, with `+`,
  `-`, `*` and parentheses (`Attempts(n * 2 + 1)`). A computed value is
  always the whole argument of a head that holds one value: a newtype
  (`Attempts(n + 1)`), a variant carrying one type
  (`Link.Failed(n + 1)`) or an element (`Scores[id](s * 2)`), never a
  factor or a whole side. Such a head takes no factors, so `*` between
  values under it is a multiplication. A plain literal or constant is a
  value too (`Attempts(0)`, `Count(Start)`), also in `__init`, which
  names no value; a lone constant may stand as a factor, as a name does.
  Every name and constant has the type the head holds, every literal
  fits it, and an operator needs an `__int` or a `__float` (or a newtype
  of one). A computed value is an error in a source, an input or a
  guard.
  `example/todomvc.sumspec` counts the items left when a todo is added.
- Guards: `// condition` after a transition's source and before `->`.
  The condition is built from patterns with `not`, `and`, `or` and
  parentheses (`not` binds tightest). A guard is read where the source
  is: after a shared path (`App =>`) its patterns are arguments of that
  path, and without one they describe the source's own type, so a guard
  sees as much of the state as the source does, and `=>` widens it. It
  binds no value, but may use a name the transition binds. The overlap
  warning for transitions of one event now also reads
  guards: two transitions with guards that exclude each other do not
  overlap, and so do comparisons of a name with a literal or variant
  (`c < 15` and `c >= 15`).
- Named constants: `BatteryLowThreshold = BatteryCharge(15)` or
  `MinimumFix = GPSFix.Fix3D` defines a fixed value with a name, used as
  either side of a comparison in a guard (`c <= BatteryLowThreshold`).
  The body is a type with one literal in parentheses, or a variant
  without a payload; the literal fits the type as in a comparison.
  A constant has the type it names, so `c` must be a `BatteryCharge`.
  It is a value, not a type: never a factor, payload, pattern, input or
  list element. It shares its name space with the types. The overlap
  warning reads a constant as its value.
- Equality on every type: `==` and `!=` now compare products, lists and
  sums with payloads, by structure, so `in` works on any list. A list
  compares in order, and a keyed list by its keys, in any order. A
  variant without a payload is a value of any sum (`x == Shape.Square`).
  `< <= > >=` still need a number or an enumeration.
- Membership in guards: `x in ys` holds when a value is an item of a list
  value, and `not (x in ys)` when it isn't. The right side is a name of a
  list type, keyed or not; the left side is a name, a literal, a variant
  or a constant of the element type. A key is tested with an element
  path: `// Todos[k]` and `// not Todos[k]`. The overlap warning takes
  the same membership or element path, true and false, to exclude each
  other, and two element paths with differently named keys can pick
  different elements, so they no longer exclude each other. `in`, like `not`, `and` and `or`, is now refused as a value name
  in a condition.
- Bare binding: `Head(#n)` names the one value inside a newtype, a
  variant carrying one type or an element that isn't a product, without
  writing its type. `Attempts(#n)` means `Attempts(Int#n)`, and all the
  rules for names apply. A newtype of a newtype binds the next value.
- Comparisons in guards: `== != < <= > >=` between a name the
  transition binds, a literal (integer `15`, decimal `1.5`, string
  `"abc"`) and a variant (`GPSFix.Fix3D`). Two values compare only if
  they have the same type; `< <= > >=` need an `__int`, a `__float` or a
  sum without payloads, which is ordered by its variants, first smallest.
  `==` and `!=` also take `__text` and an atomic with no base.
- Primitive types: `__int`, `__float` and `__text` are the built-in base
  types. An atomic gets one as its base in `__atomics`
  (`Port = __int`, `Name = __text`); a bare atomic (`Timestamp`) stays
  opaque. It is still a leaf: it takes no arguments, and can be an
  event's input or a list's key type. A primitive is written only there,
  and an atomic takes no annotations (a type that needs more is a newtype
  of it). Literals and operations come with guards. `example/todomvc.sumspec`
  gives `Count` and `Text` a base this way.
- Shared path: `=>` writes a path both sides of a transition share
  once, `Files[p] => FileState.Staged -> FileState.Modified` for
  `Files[p](FileState.Staged) -> Files[p](FileState.Modified)`. A
  shared path is a path or an element path, with no arguments, prime
  or naming; shared paths chain with `/` (`X / Y => A -> B`), and after
  the last one each side may be several factors
  (`Page.Plan => PMode.JustMap * Missions -> ...`).
- Alternatives: `S.{A | B}` in a source or a guard pattern picks some
  variants of the sum at `S`: `Flight.{Arming | Flying} -> ...`. Each
  alternative is written from `S`, may take arguments and hold more
  alternatives (`Flying(FPhase.{Approaching | Holding})`). A source is
  checked as one transition per alternative, a guard pattern as an `or`.
  There are at least two, each written once; none binds a value; a
  target, an input and `__init` have none. `example/drone.sumspec`'s
  `flightFailed` uses it.
- Branches: several transitions under the same shared paths write them
  once, then one branch per transition, each starting with `=>`:
  `:: Files[p]`, then `=> FileState.Untracked -> FileState.Staged` and
  `=> FileState.Modified -> FileState.Staged`. Each branch is a
  transition of its own, with its own names; the input is visible in
  all. A transition without a shared path has no branches.
- An event is defined once: its name and input, then all its
  transitions, each starting with `::`:
  `press :: A -> B`, then `:: C -> D` on the next line. Writing an
  event's name again is an error. The input is written once, and its
  names are visible in every transition.
- Initial state: `__init :: P` gives the state the app starts in, once
  per spec. Its head type is the root, the type of every state, so `App`
  is no longer required or special (`example/git.sumspec` drops
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
- The examples use these: `example/todomvc.sumspec` and `example/git.sumspec` have keyed
  lists (`Todos`, `Files`, `Branches`) and element paths, and
  `example/drone.sumspec` names its lists (`Points`, `MissionSummaries`).
- Annotations: `@name args` is metadata for the target, which gives it
  its meaning. The names a spec uses are listed in an `__annotations`
  block. An annotation goes after a type's name (or a newtype's body),
  after a variant, after a product member, or after a transition's
  target. Its arguments are opaque text up to the end of the line, a
  comment, or one of `@ = | * ::` outside brackets; brackets may span
  lines. The header blocks (`__atomics`, `__events`, `__annotations`)
  now come in any order. `example/drone.sumspec` uses `@control`, `@default`,
  `@status` and `@effect`.

### Tool

- The flake builds `sumspec` (`nix profile install .`, `nix run . --
  check FILE`), with its dependencies from the Nix binary cache.
- `sumspec lsp`: a language server over stdio. It publishes every parse
  error, or else every error and warning of the checker, as a document
  is opened, edited and saved. It gives the outline (types with their
  variants, atomics, constants, events, `__init`), go to definition and
  references for types, variants, events, annotations, constants and
  values (`x` to its `#x`), and semantic highlighting that tells a type
  from a variant in a path. These work on the definitions that parse
  while others don't. Neovim support is a plugin of its own,
  [sumspec.nvim](https://github.com/MohsenNz/sumspec.nvim): the
  filetype, the server's configuration, a fallback syntax file and
  spell checking in comments only.
- The language server shows a hover for each name: a type's definition,
  the sum a variant belongs to, a constant's value, an event's input and
  number of transitions, a value's type, with the comments written above
  or beside the definition (an annotation's comment in `__annotations`,
  an event's in `__events`). It completes annotations after `@`, the
  variants of a sum after `Path.` (only paths the checker accepts), the
  events not yet listed inside `__events`, and otherwise types,
  constants and the values the transition names, also on a line that
  doesn't parse yet.
- The library has a resolved model of a spec, `SumSpec.Model`: every
  type with its shape, each variant with the sum it belongs to,
  constants, events, annotations and the root type, and how a path
  resolves. It's lenient, so it works on a spec that doesn't type-check
  or holds only the definitions that parse; code generators can read a
  spec through it.
- The parser goes on after a definition that doesn't parse: it skips to
  the next line that starts in the first column and reads on, so
  `sumspec parse`, `sumspec check` and the language server report every
  broken definition at once, not only the first. An error in the
  version header or the header blocks still stops the parse. An
  annotation with a bracket left open is reported at that bracket, the
  outermost one, and the definitions after it keep their positions.
- Checker messages give generic examples (`T(n + 1)`, `L = [T]`,
  `L = [T by K]`, `__init :: T`) instead of names from one particular
  spec (`Attempts`, `Points`, `Todos`).
- The parser, printer and checker read computed values in targets. The
  canonical form writes only the parentheses the structure needs
  (`Attempts(n * 2 + 1)`, `Attempts(a - (b + 1))`).
- The example specs have the `.sumspec` extension
  (`example/drone.sumspec`, `example/todomvc.sumspec`,
  `example/git.sumspec`), like the test corpora, so editors can detect
  them.
- The parser, printer and checker read annotations. The canonical form
  puts a type's annotations after its name and writes each
  annotation's arguments on one line. The checker reports an annotation
  not listed in `__annotations` and a name listed twice there. A header
  block written twice, or a missing `__atomics` or `__events`, is
  reported by name.
- The parser, printer and checker read event inputs, named values,
  keyed lists, element paths and `__init`.
- Warnings for a variant the app never reaches from `__init`, and for
  two transitions of one event, on the same type, whose sources can
  match the same state (`example/todomvc.sumspec` warns about `deleteTodo` and
  `clearCompleted`, and `example/git.sumspec` about `merge` and
  `rebaseContinue`). `example/drone.sumspec` gains `selectMission`,
  `editMission`, `startFlight`, `takeOff`, `flightFailed`, `landed` and
  `dismissFailure`, so every variant is reached; its `PMode.Flight`
  now carries `Flight`.
- The parser, printer and checker read `=>`; the canonical form keeps
  it, and the checker checks the expanded form, reporting a problem in
  a shared path once. The examples use it: git's `Files[p]` and
  `Repository.Initialized` events, todomvc's `Todos[id]`, `App` and
  `Screen.WithTodos` events, and drone's `Page.Plan` events.
- The parser, printer and checker read alternatives. A warning about a
  transition from a source with alternatives points at the alternative
  it comes from.
- The parser, printer and checker read `/` and branches. The canonical
  form puts one branch on the line of its shared paths, and several one
  per line, each `=>` under the `::`. A warning about a transition
  points at its source, after `=>`, so branches are told apart. git's
  `Files[p]` and `Repository.Initialized` events and todomvc's
  `addTodo` and `toggleTodo` use branches.
- A warning for a transition that can never happen: its source needs a
  variant that is never reached, or its type is one no state holds.
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
- Example specs: `example/drone.sumspec`, `example/todomvc.sumspec`, `example/git.sumspec`.

### Tool

- Parser with error messages that show the line and column.
- Type checker that reports every error, sorted by position.
- CLI: `sumspec parse FILE` and `sumspec check FILE`.
- Golden tests for the parser and the checker.
