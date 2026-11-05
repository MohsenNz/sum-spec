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

This is a transition of the event `t`: when `t` happens, the app moves from state A (Type A) to state B (Type B).

We show a state (in a transition) like this:

```
trans1 :: Y.V1 -> Y.V3(A)

Z = Y * C

trans2 :: Z(Y.V1 * C) -> Z(Y.V2 * C)
```

The transition of trans1 changes state Y.V1 to Y.V3(A). We show the state of product types with parenthesis: `Z(...)`, and refer to sum types with dot `Y.V1`. The State of a variant with a value is shown like a product type, `Y.V3(A)`.

**More Examples:**

```
T2 = A
   | B (X * Y * Z)
   | C

trans3 :: T2.A -> T2.B(X * Y * Z)
```

**Note**: types are uppercase and events are lowercase

### Transition parts:

In transition `trans3 :: T2.A -> T2.B(X * Y * Z)` we call each part like this:

```haskell
trans3
-- ↑ event name
  :: T2.A
  -- ↑ source; state pattern
  -> T2.B(X * Y * Z)
  -- ↑ target     ↑ argument
```

**Event:** the name before `::`, something that happens to the app: a user's action or an occurrence in the outside world. An event may have several transitions; see "Several transitions for one event".

**Source:** the left side of ->, the state the app must be in for the transition to apply (a precondition).

**Target:** the right side of ->, the state the app is in after the transition.

**State pattern:** a description of a set of states, such as Page.Plan(PMode.JustMap), written on either side of a transition (and in its input).

**Argument:** a pattern inside the parentheses after a type or variant, saying which inner state must be there.

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

### Primitive types

`__int`, `__float` and `__text` are the built-in base types: a whole number, a number that may have a fractional part, and a piece of text. A type gets one as its base in `__atomics`:

```
__atomics {
  Timestamp         -- opaque: each target supplies it
  Port  = __int
  Ratio = __float
  Name  = __text
}
```

- Each atomic is its own type: `Port = __int` and `Count = __int` are different types.
- A primitive says what kind of value a type holds. The target picks the representation (a `__float` may be a double or a decimal). Literals and the operations on these values come with guards.
- A bare atomic (`Timestamp`) has no base: the notation does not decompose it, and each target supplies it.

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

## Naming

Types and variants are uppercase; events are lowercase.

Name an event for what happens:

- A command, something the user or another system asks for, is an imperative verb: `toggleTodo`, `startTyping`, `commit`.
- An occurrence, something that happened to the app, is in the past tense: `linkLost`, `uploadFinished`.

`Event` suffix is optional for occurrences, it's up to you to use it: `linkLossEvent`

This is a convention; the type checker doesn't check it.

Each sum has its own variant namespace. `Ring.Partial` and `Path.Partial` are different variants, and a variant may share a type's name (`PMode.Plot` is a variant, `Plot` is a type). Variant names are unique within one sum. Names inside a payload always refer to types:
in `| Plot (PlotOrigin * Plot)`, the second `Plot` is the type `Plot`.

## Transitions, more

### Sum without a variant

In a state pattern, a sum written without choosing a variant stands for any of its variants:

```haskell
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
- The **target** side is the effect. A part that is left out, or written without a prime, keeps its value. A primed part, `A'`, gets a new value, set by the transition; a prime goes only on a part that keeps its place, not inside a new state. A part whose variant differs from the source's is a **new state**.

A new state didn't exist before the transition, so nothing in it can keep its value: inside a new state, a part that is left out, or written without a prime, may have any value, and nothing takes a prime.

A part keeps its value only where the source fixes the same variants along its path. In `Page -> Page.Plan(PMode.JustMap)`, the source may have been `Page.Home`, so `Plan` is a new state.

Examples, with the types of `example/drone`:

```haskell
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
- Not twice (`A''`), while no `A'` on the source.
- Not inside a new state: `Page -> Page.Plan(PMode')` is an error.
- Right after its name: `A '` is read as `A'`, but the type checker warns about the space.

`Missions'` says that a list changed, not how (added, removed, edited).

### Several transitions for one event

An event may apply from more than one state, reaching a different
target or having a different effect from each. Write the name (and the
input) once, then one transition per state, each starting with `::`:

```
f :: A -> B
  :: C -> D
```

An event is defined once, with all its transitions together. A transition
starts with `::`, so layout doesn't matter, and comments may go between
transitions; the canonical form puts each `::` under the first.

### Event inputs

An event may take an input, a value it brings with it. The input's type
goes after the event's name:

```
startTyping Text :: NewTodo.Blank -> NewTodo.Typing(Text)
```

The input is one type: an atomic or a defined type, such as a list type
(`Ids = [Id]`).
An event that brings several values takes a product defined for them:

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

### Shared path (=>)

The two sides of a transition often start with the same path. `=>` writes it once, before both sides:

```
-- The same as: Files[p](FileState.Staged) -> Files[p](FileState.Modified)
unstage Path#p :: Files[p] => FileState.Staged -> FileState.Modified
```

`S => A -> B` means `S(A) -> S(B)`: each side is what would go inside the parentheses after `S`:

```
-- The same as: Page.Plan(PMode.JustMap * Missions)
--           -> Page.Plan(PMode.ShowMission.List * Missions)
showMission :: Page.Plan 
            => PMode.JustMap * Missions
            -> PMode.ShowMission.List * Missions
```

Shared paths chain, outermost first: `X => Y => a -> b` means `X(Y(a)) -> X(Y(b))`.

A shared path takes no arguments, prime or naming.


## Named values (#name)

A pattern followed by `#x` names the value it matches; a lowercase name
alone in a pattern stands for that value:

```
startTyping Text#t :: NewTodo.Blank -> NewTodo.Typing(t)
```

- `P#x` matches `P` and names its value `x`. `P` is any pattern headed by
  a type: `Text#t`, `Completion.Active#c`, `Ids#ids`. `#x` is one
  token: no space between `#` and the name. The canonical form writes no
  space before `#` either, and the type checker warns about one
  (`Text #t`).
- A name is given once per transition, in the input or on the source
  side. A name given in the input is visible in every transition of the
  event; one given on a source belongs to that transition. Its type is like: `Completion` for `Completion.Active#c`, `Ids` for `Ids#ids`.
- **On the source side**, a name that is used is a guard: the value there
  must equal the named one. `unlock` applies only when the entered code
  `c` equals the lock's secret:

  ```
  Lock   = Secret * State
  Secret = Code
  State  = Locked | Unlocked

  unlock Code#c :: Lock(Secret(c) * State.Locked) -> Lock(State.Unlocked)
  ```

- **On the target side**, a name sets the part to the named value:
  `Title(e)` is the title, set to the text `e`:

  ```
  startTyping Text#t :: NewTodo.Blank -> NewTodo.Typing(t)
  ```

- Names belong to one transition. Two transitions of an event may name
  their input differently.

A name says which value; a prime says only that the value is new.
`Title'` is some new title, and `Title(e)` is the title `e`.

## List

We show a list of T like: `[T]`

A list only define as a newtype and is written by a type name everywhere else:

```
Points = [Point]

Ring = Partial Points | Enclosed Points

pick Points#ps :: Ring.Partial -> Ring.Enclosed(ps)
```

- A list of lists names the inner list: `Row = [Cell]`, `Grid = [Row]`.
- A list can't be a product's factor (`[A] * B`), a variant's payload
  (`V [A]`) or a pattern (`[A]`, in an input or on a side): write its
  type name.

### Keyed lists

A keyed list, `[T by K]`, is a list whose elements are identified by a
key of type `K`:

```
Todos    = [Todo by TodoId]
Files    = [FileState by Path]
Branches = [Tip by BranchName]
```

- No two of its elements have the same key.
- `K` is an atomic or a defined type.
- `[T by K]` and `[T]` are different types, and so are two keyed lists
  with different keys.
- `by` is a word only inside the brackets; it can still be a name
  elsewhere.

An element of a keyed list is picked with an element path,
`Todos[id]`; see "Element paths".

### Element paths

`L[x]` is the element of the keyed list type `L` whose key equals the named value `x`:

```
Todos = [Todo by TodoId]
Todo  = Title * Completion * RowMode

toggleTodo TodoId#id :: Todos[id](Completion.Active) -> Todos[id](Completion.Completed)
```

`Todo[id]` will be resolved to a `Todo` and then `(Completion.Active)` will apply
to that `Todo`: `Todo(Completion.Active)`.

- `L` is a type defined as a keyed list (`Todos = [Todo by TodoId]`).
  The path starts at the list type, so from a variant that carries the
  list: `Ring.Points(Points[i](...))`.
- On the source side, `L[x]` is a precondition: the element exists and
  matches its arguments. Without arguments, it only has to exist.
- On the target side, `L[x](...)` is that element's new state.
  Without arguments, the element keeps its value.
- An element takes no prime (`Todos[id]'`): prime its parts instead,
  `Todos[id](Title')`. It can't be named (`Todos[id]#t`) either, and it
  doesn't go in the input.

**More Examples:**

```
deleteTodo TodoId#id :: Screen.WithTodos(Todos[id]) -> Screen.NoTodos
```

A path is written from where the list is, so the parts around it can be
written too.

```
Projects = [Project by ProjectId]
Project  = Name * Todos
Ref      = ProjectId * TodoId

toggleTodo Ref(ProjectId#p * TodoId#t)
  :: Projects[p](Todos[t](Completion.Active))
  -> Projects[p](Todos[t](Completion.Completed))
```

A path picks an element of each list it goes through, so nested lists work.
`Projects[p]` is the project, and `Todos[t]` the todo inside it.

## Language version

A spec may declare the language version it's written for, as the first
line (a comment may come before it):

```
__version 1.0
```

The version is `major.minor`, written as one token (`1.0`, not `1. 0`).
A spec without the header is version 1.0. See `VERSIONING.md` for 
how versions are numbered.

## Initial state (__init)

`__init :: P` gives the state the app starts in. `P` is a state pattern, like a target. Every spec has exactly one `__init`, written among the definitions (after `__atomics` and `__events`).

`P` is a whole new state: nothing has a value before it, and no event brings an input. So:

- A part that is left out may have any value.
- Nothing in it takes a prime (`__init :: App(Mode')` is an error).
- Nothing in it is named or uses a name (`Text#t`, `x`), and it has no element path (`Todos[id]`).
- `__init` isn't listed in `__events`, and no `->` follows the `::`.

`__atomics` and `__events` are written before any type, transition or `__init`.

## Summary:

`=`  used for type definition
`|`  sum type
`*`  product type
`.`  selects a variant of a sum type
`::` starts a transition
`->` state transition
`=>` a path both sides of a transition share

## Example

```
__atomics {
  A
  B
  C
}

__events {
  trans1
  trans2
}

-- The app starts with Y at V1; C may have any value.
__init :: Z(Y.V1)

Z = Y * C

Y = V1
  | V2
  | V3 A

trans1 :: Y.V1 -> Y.V3(A)

trans2 :: Z(Y.V1 * C) -> Z(Y.V2 * C)
```

The root is `Z`. In `example/drone`, the app starts on the home page:

```
__init :: App(Page.Home)
```

## Warnings

Transitions of one event on different types describe its effect on different parts, and all of them happen (`commit` in `example/git` changes the branch and the files). Two transitions on the same type should have sources that exclude each other: somewhere, they pick different variants. Otherwise one state can match both, and the spec doesn't say which happens; the type checker warns:

```
-- Warned: Level is left out of the second source, so it may be Low.
press :: App(Mode.Off * Level.Low) -> App(Mode.On)
      :: App(Mode.Off) -> App(Level.High)
```

The check reads only variants: two sources that differ only in a named value (`Todos[a]`, `Todos[b]`) are taken to overlap.

From `__init`, the type checker finds the variants the app can reach: a transition can happen once every variant its source writes has been reached, and its target then reaches the variants it writes. A part that may have any value (left out of `__init` or of a new state, or primed) reaches every variant inside it. The checker warns about a variant of a type inside the app's state that is never reached, and reports only the outermost one (not `Bolt` inside an unreached `Locked (Bolt | Chain)`). Parts of a source are tested one at a time and names are ignored, so a variant may be counted as reached when the app can't really get there, but never the other way around.

A transition whose source writes a variant that is never reached, or whose type no state holds (a type outside the app's state), can never happen, and the type checker warns about it, naming the outermost variant its source needs. Such a transition also adds nothing, so what only it would reach is reported as never reached as well.
