# SumSpec

This document defines SumSpec **1.0**.

## Comments

A comment starts with `--` and runs to the end of the line. It can go anywhere whitespace can, on its own line or after code:

```
-- Where the user is in the app
Page
  = Home
  | Plan    (PMode * Missions)  -- planning a mission
  | Devices
```

## Types

In SumSpec we express state with type, so a type here is equivalent to a state in state-machine.

### Product Type

```
T = A * B
```

This is a type named T that is a product of A and B.

### Sum Type

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

## State Transitions

```
t :: A -> B
```

Transition t transfer app from state A (Type A) to state B (Type B).

We show a state (in a transition) like this:

```
trans1 :: Y.V1 -> Y.V3(A)

Z = Y * C

trans2 :: Z(Y.V1 * C) -> Z(Y.V2 * C)
```

The trans1 transition, change state Y.V1 to Y.V3(A). We show the state of product types with parenthesis: `Z(...)`, and refer to sum types with dot `Y.V1`. The State of a variant with a value is shown like a product type, `Y.V3(A)`.

**More Examples:**

```
T2 = A
   | B (X * Y * Z)
   | C

trans3 :: T2.A -> T2.B(X * Y * Z)
```

**Note**: types are uppercase and transitions are lowercase

In transition `trans3 :: T2.A -> T2.B(X * Y * Z)` we call each part like this:

```haskell
trans3
-- ↑ transition name
  :: T2.A
  -- ↑ source; state pattern
  -> T2.B(X * Y * Z)
  -- ↑ target     ↑ argument
```

**Source:** the left side of ->, the state the app must be in for the transition to apply (a precondition).

**Target:** the right side of ->, the state the app is in after the transition (the effect).

**State pattern:** a description of a set of states, such as Page.Plan(PMode.JustMap), written on either side of a transition (and in its input).

**Argument:** a pattern inside the parentheses after a type or variant, saying which state an inner part of that state must be in.

### Summary:

`=`  used for type definition
`|`  sum type
`*`  product type
`.`  selects a variant of a sum type
`::` transition definition
`->` state transition

## Types, more

### Products are keyed by type

A product's components are identified by their type names, so a type appears at most once in a product (that's why `T = A * A` is invalid).

The order of components doesn't matter, so these are the same state:

```
Z(Y.V1 * C)
Z(C * Y.V1)
```

### NewType

`T = A` defines a newtype: `T` has the same structure as `A` but is a different type, never equal to `A`. So the following is valid:

```
At = Timestamp
T  = At * Timestamp
```

Loop is not allowed (`A = B`, `B = A` is invalid).

### Inline payloads and paths

A variant's payload may be an inline product or an inline sum, nested to any depth:

```
PMode
  = JustMap
  | Plot        (PlotOrigin * Plot)
  | ShowMission
      ( List
          ( Empty
          | NonEmpty MissionSummaries
          )
      | Selected Mission
      )
```

A path selects nested variants with dots: `PMode.ShowMission.List.Empty`.

A list isn't inline: it has a type name (`MissionSummaries = [MissionSummary]`); see "List".

## Transitions more

### Sum without a variant

In a state pattern, a sum written without choosing a variant stands for any of its variants:

```
showMission :: Page.Plan(PMode.JustMap * Missions)
            -> Page.Plan(PMode.ShowMission.List * Missions)
```

Here the target is `List.Empty` or `List.NonEmpty(...)`: `List` is a new state (see "Source and target"), so either variant is possible.

### Arguments in state patterns

In a state pattern, the arguments are what goes inside the parentheses after a type or variant.
They narrow down what the inner parts of the state must be.

Arguments may be left out: a bare type (`Missions`), a bare sum (`PMode.ShowMission.List`) and a variant with a payload (`Page.Plan`) can each be written without them. What a left-out part means depends on the side of the transition; see "Source and target".

When arguments are written, they must fit what they follow:

- A product, or a variant carrying a product, takes some or all of its factors, in any order, each at most once: `Z(C * Y.V1)`, `Z(C)`.
- A variant carrying one type takes one argument headed by that type: `Y.V3(A)`, `Plot.Drawn(Boundary)`.
- A newtype takes one argument headed by its base type. With `Boundary = Ring`, write `Boundary(Ring.Enclosed)`, not `Boundary.Enclosed`.
- A sum takes no arguments; pick a variant with `.` instead.
- An atomic type, and a variant without a payload, take no arguments.
- A list type takes no arguments; pick an element with an element path instead (`Todos[id](...)`).

An argument may also be a named value (`t`), which fits where its type is expected; see "Named values". An element path (`Todos[id]`) fits where its list type is expected; see "Element paths".

A path continues with `.` only into a sum: a named sum or an inline sum payload. To pick a variant of a payload that is a named type, use an argument: `Page.Plan(PMode.JustMap * Missions)`.

The two sides of a transition are states of the same type: they're headed by the same type name. `Page.Home -> Page.Plan` is valid, `Page.Home -> Missions` isn't. An element path is headed by its list type, so `Todos[id](...)` is a state of `Todos`.

### Source and target

The two sides of a transition are read differently:

- The **source** side is a precondition. A part that is left out may have any value.
- The **target** side is the effect. A part that is left out, or written without a prime, keeps its value. A primed part, `A'`, gets a new value, set by the transition. A part whose variant differs from the source's is a **new state**. A named value (`Title(e)`) sets the part to that value; see "Named values".

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

Every signature of a transition takes the same input, or none; see
"Transition inputs".

## Transition inputs

A transition may take an input, a value the event brings with it. The
input's type goes after the transition's name:

```
startTyping Text :: NewTodo.Blank -> NewTodo.Typing(Text)
```

The input is one type: an atomic or a defined type, such as a list type
(`Ids = [Id]`).
A transition that needs several values takes a product defined for them:

```
Ref = Id * Name

select Ref :: State.Off -> State.On
```

The input is a pattern headed by its type, read like a source pattern.
It can name the input or its parts (see "Named values"):

```
startTyping Text#t :: NewTodo.Blank -> NewTodo.Typing(t)
select Ref(Id#i * Name#n) :: Item(i * State.Off) -> Item(State.On)
```

A variant or argument written in the input is a precondition on it, as
on the source side.

The input belongs to the transition, not to one signature: like an
event of a state machine, a transition has one input, whatever state it
applies from. So every signature writes an input of the same type, or
none (the names in it may differ):

```
toggleTodo TodoId :: Completion.Active -> Completion.Completed
toggleTodo TodoId :: Completion.Completed -> Completion.Active
```

A signature doesn't have to use the input.

## Named values

A pattern followed by `#x` names the value it matches; a lowercase name
alone in a pattern stands for that value:

```
startTyping Text#t :: NewTodo.Blank -> NewTodo.Typing(t)

finishEditing TodoId#id :: Todo(id * RowMode.Editing(EditText(Text#e)))
                        -> Todo(Title(e) * RowMode.Viewing)
```

- `P#x` matches `P` and names its value `x`. `P` is any pattern headed by
  a type: `Text#t`, `Completion.Active#c`, `Ids#ids`. `#x` is one
  token: no space between `#` and the name. The canonical form writes no
  space before `#` either.
- A name is given in the input or on the source side, once per
  signature. Its type is the type `P` is headed by (`Completion` for
  `Completion.Active#c`).
- A name is used anywhere in the signature, where its type is expected:
  as an argument (`Typing(t)`), as a product's factor, where it stands
  for the factor of its type (`Todo(id * ...)`), or as the key of an
  element path (`Todos[id]`; see "Element paths").
- On the source side, a name used stands for a value that must be equal
  to the named one: `Todo(id * ...)` matches the todo whose `TodoId`
  equals the input `id`.
- On the target side, a name sets the part to the named value:
  `Title(e)` is the title, set to the text that was being edited.
- Names belong to one signature. Two signatures of a transition may name
  their input differently.

A name says which value; a prime says only that the value is new.
`Title'` is some new title, and `Title(e)` is the title `e`.

### Keys

A transition written on a part inside a list element (`toggleTodo` on
`Completion`, inside `Todos = [Todo]`) changes one element, but doesn't
say which:

```
toggleTodo :: Completion.Active -> Completion.Completed
```

In a list without a key, pick the element by writing the transition
from the element and comparing a key factor with a named input:

```
Todos = [Todo]
Todo  = TodoId * Title * Completion * RowMode

toggleTodo TodoId#id :: Todo(id * Completion.Active) -> Todo(Completion.Completed)
```

Here `toggleTodo` changes the todo whose `TodoId` equals the input.

This form picks only the innermost element: inside nested lists
(`Projects = [Project]`, `Project = ProjectId * Todos`), the project
isn't picked. Nothing says that two todos can't have the same `TodoId`,
either. A keyed list with element paths does both; see "Keyed lists"
and "Element paths".

The type checker warns about a transition inside a list element that
doesn't pick the element, by key or with an element path.

## Element paths

`L[x]` is the element of the keyed list type `L` (see "Keyed lists")
whose key equals the named value `x`. It's written where `L` is
expected, and the arguments after it are the element's:

```
Todos = [Todo by TodoId]
Todo  = Title * Completion * RowMode

toggleTodo TodoId#id :: Todos[id](Completion.Active) -> Todos[id](Completion.Completed)
```

- `L` is a type defined as a keyed list (`Todos = [Todo by TodoId]`).
  The path starts at the list type, so from a variant that carries the
  list, the list type is its argument: `Ring.Points(Points[i](...))`.
- `x` is a name given in the input or on the source side, of the list's
  key type (`TodoId`).
- The arguments are the element's. When the element type is a product,
  they're its factors: `Todos[id](Completion.Active)`. Otherwise, the
  element takes one argument headed by its type, as a variant's payload
  does: with `Files = [FileState by Path]`, write
  `Files[p](FileState.Staged)`.
- On the source side, `L[x]` is a precondition: the element exists and
  matches its arguments. Without arguments, it only has to exist.
- On the target side, `L[x](...)` is that element's new state, read as
  any target. Without arguments, the element keeps its value.
- The key isn't part of the element, so an element can't change it.
- An element takes no prime (`Todos[id]'`): prime its parts instead,
  `Todos[id](Title')`. It can't be named (`Todos[id]#t`) either, and it
  doesn't go in the input.

A path is written from where the list is, so the parts around it can be
written too:

```
deleteTodo TodoId#id :: Screen.WithTodos(Todos[id]) -> Screen.NoTodos
```

A path picks an element of each list it goes through, so nested lists
work:

```
Projects = [Project by ProjectId]
Project  = Name * Todos
Ref      = ProjectId * TodoId

toggleTodo Ref(ProjectId#p * TodoId#t)
  :: Projects[p](Todos[t](Completion.Active))
  -> Projects[p](Todos[t](Completion.Completed))
```

`Projects[p]` is the project, and `Todos[t]` the todo inside it.

## List

We show a list of T like: `[T]`

A list goes only as the whole body of a type definition, so every list
has a type name, and is written by it everywhere else:

```
Points = [Point]

Ring = Partial Points | Enclosed Points

pick Points#ps :: Ring.Partial -> Ring.Enclosed(ps)
```

- A list's element is a type name too. A list of lists names the inner
  list: `Row = [Cell]`, `Grid = [Row]`.
- A list isn't a product's factor (`[A] * B`), a variant's payload
  (`V [A]`) or a pattern (`[A]`, in an input or on a side): write its
  type name.
- A list type takes no arguments; see "Element paths" to pick an
  element.

### Keyed lists

A keyed list, `[T by K]`, is a list whose elements are identified by a
key of type `K`:

```
Todos    = [Todo by TodoId]
Files    = [FileState by Path]
Branches = [Tip by BranchName]
```

- The list is ordered, and no two of its elements have the same key.
- The key belongs to the list, not to the element: `Todo` has no
  `TodoId`. So any type can be an element, including a sum
  (`FileState`) or an atomic.
- `K` is an atomic or a defined type.
- `[T by K]` and `[T]` are different types, and so are two keyed lists
  with different keys.
- `by` is a word only inside the brackets; it can still be a name
  elsewhere.

An element of a keyed list is picked with an element path,
`Todos[id]`; see "Element paths".

## Naming

Types and variants are uppercase; transitions are lowercase.

Each sum has its own variant namespace. `Ring.Partial` and `Path.Partial` are different variants, and a variant may share a type's name (`PMode.Plot` is a variant, `Plot` is a type). Variant names are unique within one sum. Names inside a payload always refer to types: in `| Plot (PlotOrigin * Plot)`, the second `Plot` is the type `Plot`.

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
