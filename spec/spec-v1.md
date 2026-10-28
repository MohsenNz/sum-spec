# SumSpec

SumSpec is a language defined in our application specification with types and transitions. It uses type-theory (sum-type and product-type) and state machine to describe the system (application).

This document defines SumSpec **1.x**; the current version is **1.0**. Features added in a later 1.x version carry an "Added in 1.x" note under their heading; see `VERSIONING.md`.

## State transitions

```
t :: A -> B
```

Transition t transfer app from state A (Type A) to state B (Type B).

## Type definition

```
T = A * B
```

This is a type named T that is a product of A and B.

```
Y = V1 | V2
```

The type Y has two variants V1 and V2. Each variant can carry one optional Type too.

```
Y = V1
  | V2
  | V3 A
```

Now Y is a sum of V1, V2 and `V3 A`.

We show the state (e.g in a transition) like:

```
trans1 :: Y.V1 -> Y.V3(A)
```

or:

```
Z = Y * C

trans2 :: Z(Y.V1 * C) -> Z(Y.V2 * C)
```

The trans1 transition, change state Y.V1 to Y.V3(A). We show the state of product types with parenthesis: `Z(...)`, and refer to sum types with dot `Y.V1`. The State of a variant with a value is shown like a product type, `Y.V3(A)`.

**Summary**

`=`  used for type definition
`|`  sum type
`*`  product type
`.`  selects a variant of a sum type
`::` used for transition definition
`->` state transition

**More Examples**

```
T2 = A
   | B (X * Y * Z)
   | C

trans3 :: T2.A -> T2.B(X * Y * Z)
```

**Invalid Examples**

```
T = A * A
```

**Note**: types are uppercase and transitions are lowercase

### Products are keyed by type

A product's components are identified by their type names, so a type appears at most once in a product (that's why `T = A * A` is invalid).

The order of components doesn't matter, so these are the same state:

```
Z(Y.V1 * C)
Z(C * Y.V1)
```

`T = A` defines a newtype: `T` has the same structure as `A` but is a different type, never equal to `A`. So the following is valid:

```
At = Timestamp
T  = At * Timestamp
```

Newtypes are how two values of the same underlying type go into one product.

A chain of newtypes must not lead back to where it started (`A = B`, `B = A` is invalid).

In a state pattern, a product's arguments may leave out factors; see "Source and target".

### Inline payloads and paths

A variant's payload may be an inline product or an inline sum, nested to any depth:

```
PMode
  = JustMap
  | Plot        (PlotOrigin * Plot)
  | ShowMission
      ( List
          ( Empty
          | NonEmpty [MissionSummary]
          )
      | Selected Mission
      )
```

A path selects nested variants with dots: `PMode.ShowMission.List.Empty`.

## Sum without a variant

In a state pattern, a sum written without choosing a variant stands for any of its variants:

```
showMission :: Page.Plan(PMode.JustMap * Missions)
            -> Page.Plan(PMode.ShowMission.List * Missions)
```

Here the target is `List.Empty` or `List.NonEmpty(...)`: `List` is a new state (see "Source and target"), so either variant is possible.

## Arguments in state patterns

Arguments may be left out: a bare type (`Missions`), a bare sum (`PMode.ShowMission.List`) and a variant with a payload (`Page.Plan`) can each be written without them. What a left-out part means depends on the side of the transition; see "Source and target".

When arguments are written, they must fit what they follow:

- A product, or a variant carrying a product, takes some or all of its factors, in any order, each at most once: `Z(C * Y.V1)`, `Z(C)`.
- A variant carrying one type takes one argument headed by that type: `Y.V3(A)`, `Ring.Closed([Point])`.
- A newtype takes one argument headed by its base type. With `Boundary = Ring`, write `Boundary(Ring.Enclosed)`, not `Boundary.Enclosed`.
- A sum takes no arguments; pick a variant with `.` instead.
- An atomic type, and a variant without a payload, take no arguments.

A path continues with `.` only into a sum: a named sum or an inline sum payload. To pick a variant of a payload that is a named type, use an argument: `Page.Plan(PMode.JustMap * Missions)`.

The two sides of a transition don't have to be states of the same type.

## Source and target

The two sides of a transition are read differently:

- The **source** side is a precondition. A part that is left out may have any value.
- The **target** side is the effect. A part that is left out, or written without a prime, keeps its value. A primed part, `A'`, gets a new value, set by the transition. A part whose variant differs from the source's is a **new state**.

A new state didn't exist before the transition, so nothing in it can keep its value: inside a new state, a part that is left out may have any value.

A part keeps its value only where the source fixes the same variants along its path. In `Page -> Page.Plan(PMode')`, the source may have been `Page.Home`, so `Plan` is a new state.

Examples, with the types of `example/drone`:

```
-- Only the mode changes; Missions keeps its value.
changeMode :: Page.Plan(PMode * Missions) -> Page.Plan(PMode' * Missions)

-- The same, with the unchanged part left out.
changeMode :: Page.Plan -> Page.Plan(PMode')

-- The mode and the missions both change.
changeAll :: Page.Plan -> Page.Plan(PMode' * Missions')

-- The source leaves out Markings, so any markings match. The target
-- enters a new state, ShowMission.Selected, whose Mission may have any
-- value; Missions gets a new value.
savePlot :: Page.Plan(PMode.Plot(PlotOrigin.Draft * Plot.Drawn(Boundary(Ring.Enclosed))))
         -> Page.Plan(PMode.ShowMission.Selected * Missions')

-- Plan is a new state: PMode is set, and Missions may have any value.
goToPlan :: Page.Home -> Page.Plan(PMode.JustMap)
```

Where a prime may go:

- Only on a bare type name (`A'`, `Missions'`), and only on the target side.
- Not twice (`A''`), and not on a path, after arguments, or on a list (`PMode.Plot'`, `Footer(ItemsLeft)'`, `[Point]'`): a written variant or argument already says what the new value is.
- A prime doesn't make a new factor: `A * A'` writes the factor `A` twice.

`Missions'` says that a list changed, not how (added, removed, edited).

## Several signatures for one transition

A transition may apply from more than one state, reaching a different
target or having a different effect from each. Repeat the name, one
block per signature:

```
f :: A -> B
f :: C -> D
```

## List

We show a list of T like: `[T]`

## Naming

Types and variants are uppercase; transitions are lowercase.

Each sum has its own variant namespace. `Ring.Partial` and `Path.Partial` are different variants, and a variant may share a type's name (`PMode.Plot` is a variant, `Plot` is a type). Variant names are unique within one sum. Names inside a payload always refer to types: in `| Plot (PlotOrigin * Plot)`, the second `Plot` is the type `Plot`.

## Comments

A comment starts with `--` and runs to the end of the line. It can go anywhere whitespace can, on its own line or after code:

```
-- Where the user is in the app
Page
  = Home
  | Plan    (PMode * Missions)  -- planning a mission
  | Devices
```

Comments are for human readers and don't change the spec.

## Language version

A spec may declare the language version it's written for, as the first
line (a comment may come before it):

```
__version 1.0
```

The version is `major.minor`, written as one token (`1.0`, not `1. 0`).
A spec without the header is version 1.0. A tool that doesn't implement
the declared version stops at the header with an error that names the
version. See `VERSIONING.md` for how versions are numbered.

## Entry point

The entry point is type `App`. Every spec should carry it. Also all then transition names should declare inside `__txs {}` block and all leaf types (atomic types) declare inside `__atomics {}` block as the start point.

### Example

```
__atomics {
  A
  B
  C
}

__txs {
  trans1
  trans2
}

App = Z

Z = Y * C

Y = V1
  | V2
  | V3 A

trans1 :: Y.V1 -> Y.V3(A)

trans2 :: Z(Y.V1 * C) -> Z(Y.V2 * C)
```

`__atomics` and `__txs` should define before each type or transition, but they don't have any priority to each others.
