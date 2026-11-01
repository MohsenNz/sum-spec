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

## Element paths through a variant

Version impact: additive.

    Ring = Open | Points [Point by PointId]

    move PointId#i :: Ring.Points[i](...) -> Ring.Points[i](...)

An element path picks from a variant's inline keyed list, written as
the path to the variant. In 1.2 only a named list type can be picked
from (`Points = [Point by PointId]`); see "Element paths" in
`spec-v1.md`.

## Naming an element

Version impact: additive.

    rename TodoId#id :: Todos[id]#t -> ...

`L[x]#t` names the element, with the element type (`Todo`), not the
list type. Not allowed in 1.2.
