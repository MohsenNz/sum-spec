# Proposals

Ideas that are in no language version yet. Each one says its version
impact (see `VERSIONING.md`):

- **additive**: it can go into the next minor language version
- **breaking**: it waits for the next major language version

## Two state transitions with the same signature

Version impact: additive.

    g, h :: Y -> Z  -- two state transitions "g" and "h" with the same signature

## transition that also takes an input

Version impact: additive.

    f X :: A -> B

Transition f takes an X and moves the state from A to B.
The input is a single type; a transition needing several values takes a
product type defined for them.

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
