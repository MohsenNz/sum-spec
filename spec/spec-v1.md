# SumSpec

SumSpec is a language we define in our application specification, with types and transitions.
It utilize type-theory (sum-type and product-type) and state machine to describe the system (application).

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

Type names are nominal: an alias is a separate name, so the following is valid:

```
At = Timestamp
T  = At * Timestamp
```

Aliases are how two values of the same underlying type go into one product.

In a state pattern, every component of a product has to be written.

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

In a state pattern, a sum written without choosing a variant means any of its variants:

```
showMission :: Page.Plan(PMode.JustMap * Missions)
            -> Page.Plan(PMode.ShowMission.List * Missions)
```

Here the target is `List.Empty` or `List.NonEmpty(...)`.

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
