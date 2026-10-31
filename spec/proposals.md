# Proposals

Ideas that are in no language version yet. Each one says its version
impact (see `VERSIONING.md`):

- **additive**: it can go into the next minor language version
- **breaking**: it waits for the next major language version

## Two state transitions with the same signature (Postponed)

Version impact: additive.

    g, h :: Y -> Z  -- two state transitions "g" and "h" with the same signature

## `=>` enters one construction level shared by both sides of a transition

Version impact: additive.

    t :: P.V1(A.H) -> P.V1(A.G)

To be:

    t :: P.V1 => A.H -> A.G

The source and target of a transition usually share a construction
path. `=>` enters one level of it, so the shared part is written once:

    X => Y => A -> B    means    X(Y(A)) -> X(Y(B))

## `<-` is a shorthand, `a' <-` means `a -> a'`

Version impact: additive.

    X => Y => A' * B' <-

Means:

    X(Y(A' * B')) <-

## `@` annotation

Version impact: additive.

An annotation is metadata.

Annotations add application-level metadata to definitions.
Annotations come after the type name in a type definition:

    T <Annotations> = ...

Or

    T = A <Annotations>
    T = A <Annotations> * ...
    T = A <Annotations> | ...

Or after a function definition:

    f :: A -> B <Annotations>

Available annotations should be defined inside __annotations.
A type the notation does not decompose is declared inside __atomics. An
atomic has no members here; each target supplies it.

## Dependent type

Version impact: additive.

    BoundedList = { xs : [Int] // 2 <= xs.len /\ xs.len <= 10 }

## Generic type

Version impact: additive.

    List a = [a]

## Variant refinement

Version impact: additive.

    PMode.ShowMission = List | Selected Mission

A variant declared without a payload gets its payload from a separate
definition, addressed by its path. Today the payload is written inline:

    PMode
      = ...
      | ShowMission (List (...) | Selected Mission)

## Several signatures under one name

Version impact: additive.

    toggleTodo TodoId#id
      :: Todo(id * Completion.Active)    -> Todo(Completion.Completed)
      :: Todo(id * Completion.Completed) -> Todo(Completion.Active)

A transition writes its name and input once, then one `:: source ->
target` arm per signature. Today the name and input are repeated for
each signature (see "Several signatures for one transition" in
`spec-v1.md`); that form stays valid.

    transition = LOWER , [ input ] , signature , { signature } ;
    signature  = "::" , pattern , "->" , pattern ;

An arm starts with `::`, which can't begin a definition, so the parser
knows where the next arm starts.

- Names bound in the input are visible in every arm. Names bound in a
  source belong to that arm.
- The input belongs to the transition, as in 1.1, so it's written in
  one place.

Writing the source first and grouping events below it (a state table)
was considered and rejected: an event's signatures end up in several
groups, and once patterns pick list elements by key, few sources are
shared. A tool can print the by-state view instead (e.g. `sumspec
states FILE`).

Open:

- Does the canonical form print every signature of a name as one group?
- Must the signatures of a name then be adjacent?

## Element paths `L[x]`

Version impact: additive.

    toggleTodo TodoId#id
      :: Screen.WithTodos(Todos[id](Completion.Active))
      -> Screen.WithTodos(Todos[id](Completion.Completed))

    deleteTodo TodoId#id
      :: Screen.WithTodos(Todos[id])
      -> Screen.WithTodos(Todos' * ToggleAll' * Footer')

`L[x]` is the element of the list `L` whose key equals the named value
`x`. Keys are types: the element type of `L` must have exactly one
factor of `x`'s type (`Todo` has one `TodoId`). Arguments after `L[x]`
are read as arguments of the element type.

- On the source side, `L[x]` is a precondition: the element exists and
  matches its arguments.
- On the target side, `L[x](...)` is that element's new state.
- Nested lists: a path picks an element of each list (see below).

**Nested lists.** With projects that each hold their todos:

    Projects = [Project]
    Project  = ProjectId * Todos
    Todos    = [Todo]
    Todo     = TodoId * Title * Completion * RowMode

toggling one todo picks two elements: the project, and the todo in it.
In 1.1, `Todo(id * ...)` picks the todo but not the project, so if todo
ids are unique only within a project, which todo changes isn't said.
Writing from the project, `Project(p * Todos)`, picks the project, but a
pattern can't go inside `Todos` to pick a todo. Only the innermost
element can be picked (see gap 1 in `efsm-gaps.md`). With a path, each
list takes its own key:

    Ref = ProjectId * TodoId

    toggleTodo Ref(ProjectId#p * TodoId#t)
      :: Projects[p](Todos[t](Completion.Active))
      -> Projects[p](Todos[t](Completion.Completed))

`Projects[p]` picks the project, and `Todos[t]` the todo inside it.

The 1.1 idiom, `Todo(id * ...)` written from the element, stays valid.
The key warning could suggest `L[x]` instead.

Not covered here, see gap 3 in `efsm-gaps.md`:

- Removal: the target of `deleteTodo` still says only `Todos'`, not
  that the element `id` is gone (Part C, an action clause:
  `// __remove ts[id]`).
- The second signature, `Screen.NoTodos` when the last todo goes, and
  `ToggleAll'` and `Footer'`, which follow from the list (Part B,
  derived values).

Open:

- May an element take a prime (`Todos[id]'`)?
- Is `L[x]` allowed on an inline list (`[Todo]`), or only on a named
  list type?
