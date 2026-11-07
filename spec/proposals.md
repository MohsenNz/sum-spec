# Proposals

Ideas that are in no language version yet. Each one says its version
impact (see `VERSIONING.md`):

- **additive**: it can go into the next minor language version
- **breaking**: it waits for the next major language version

Until the first release, any proposal can go straight into 1.0 (see
"Before the first release" in `VERSIONING.md`).

## Two events with the same transition (Postponed)

Version impact: additive.

    g, h :: Y -> Z  -- two events "g" and "h" with the same transition

## `<-` is a shorthand, `a' <-` means `a -> a'`

Version impact: additive.

It builds on shared paths, which are in v1 (see "Shared path" in `spec-v1.md`):

    X / Y => A' * B' <-

Means:

    X(Y(A' * B')) <-

## Annotation argument kinds

Version impact: additive.

Builds on annotations (see "Annotations (@name)" in `spec-v1.md`), whose
arguments are opaque text today. A declaration may state its argument
kind, so the checker validates it:

    __annotations {
      @unless <pattern>   -- unavailable while this state holds
      @when   <pattern>
      @control <name>
    }

For a `<pattern>` argument the checker can resolve every name against the
types, and warn when the pattern can never hold, always holds, or
contradicts the transition's source (`@unless Page.Home` on a transition
from `Page.Home`).

An atomic takes no annotations: a type that needs `@default` or `@range`
is a newtype of it.

## Core and UI specs

Version impact: additive. A spec without an import reads as it does
today.

An application has a core (the domain: its data, commands and
occurrences) and a UI (pages, modes, forms). They are two specs, and the
UI depends on the core, never the other way round. The core is the
source of truth and is complete on its own; the UI is its own small view
state plus a view of the core.

The alternatives fail:

- One spec for both (as `temp` does): view state (`Page`, `PMode`) sits
  in the domain, drawing annotations crowd it, and `@from` and `@edits`
  exist only to copy core data into the view. The core can't serve a CLI,
  an API or a second UI.
- Two independent specs: nothing checks that the UI shows fields the
  core has, or fires events the core defines, so they drift.

### Import

The UI imports the core in a header block, and names everything the core
declares with a qualifier. Its root holds the core's root as a factor;
products are keyed by type, so this is an ordinary product:

    __import core "drone-core.sumspec"

    App  = View * core.App
    View = Home | Plan PlanView | Failure

### Three kinds of UI event

- **View-only**: it changes only the UI's own state.

      goToPlan :: App => View.Home -> View.Plan

- **Dispatching**: a UI transition fires a core event, and both happen as
  one step. The core event is named after the target:

      startClicked :: App => View.Plan -> View.Flight  >> core.startFlight

- **Reaction**: the UI adds view changes to a core event, often an
  occurrence, by giving transitions for its name. They happen with the
  core's transition, as one step:

      core.flightFailed :: App => View.Flight -> View.Failure

### Reading the core

UI sources and guards may match the core's state through its root, so the
UI reads core data instead of copying it:

    retryClicked :: App => View.Failure * core.App(core.Flight.Failed)
                        -> View.Plan  >> core.retry

This replaces most `@from`. `@edits` becomes a form that holds a draft in
the view, and submitting it dispatches a core event with the draft as the
input.

### Checker rules

- A UI transition never changes a core type: no core type goes on the
  target side of a UI transition. Core state changes only through core
  events.
- A qualified name is one the import declares; a dispatched core event,
  and a core event with reactions, exists in the core.
- The core spec checks on its own, with no knowledge of the UI.
- Warning: a dispatching transition whose source can hold in a state
  where the dispatched core event can't happen (none of its sources
  matches the core part).
- Warning: a core command that no UI transition dispatches.

### Relations

- "Two events with the same transition": `startClicked, core.startFlight
  ::` could also say "these happen together", but the UI would restate the
  core's change. `>>` keeps the core's change written once, in the core.
- `@announce` and `@stream` become annotations on reactions, and
  `@control` stays on dispatching and view-only transitions.

Open:

- How the core marks occurrences (from the system or the world) apart
  from commands (from a user), for the "never dispatched" warning.
- Whether one transition may dispatch several core events, and in which
  order.
- Import paths, several imports, and renaming (`as`); an import cycle is
  an error.
- An input on a dispatched event: how the UI passes a value it binds
  (`>> core.select(id)`).
- Splitting `example/drone.sumspec` into a core and a UI to try it.

## Checking `@default` and `@range`

Version impact: additive.

Builds on the primitive types and the comparisons of v1 (see "Primitive
types" and "Comparing values" in `spec-v1.md`), and on annotations
(see "Annotations (@name)" in `spec-v1.md`). A newtype over an atomic
carries the annotations, since an atomic takes none:

    __atomics { Port = __int  Meters = __float }

    PortSetting = Port    @default 14550 @range 1..65535
    SprayHeight = Meters  @default 3 @range 1..10

The checker can then verify that a `@default` is a literal of the type,
that `@range low..high` has `low <= high`, and that the default lies
inside the range. Today these are opaque tokens. `Percent` (`0..100`) and
`Degrees` (`0..360`) would be `__float` newtypes with a `@range` instead
of atomics with a comment.

## Literal patterns

Version impact: additive.

A literal pattern says "the value is this literal": `Type(literal)`. It
is a pattern, so it goes where a pattern goes. The decisions behind it
are in `literal-patterns.md`.

    Count(0)    Meters(1.5)    Name("main")

Syntax:

- Only the form `Type(literal)`. A bare `0` is not a pattern.
- A literal is an integer (`15`, `-1`), a decimal (`1.5`) or a string
  (`"abc"`), as in "Comparing values" in `spec-v1.md`.
- A payload pattern starts with an uppercase type name, and a literal
  with a digit, `-` or `"`, so the first token after `(` tells them apart.
  `A(1)` is a syntax error today, so no spec changes meaning.
- A literal is not the payload of a variant directly: write
  `NewTodo.Typing(Text("hi"))`, not `NewTodo.Typing("hi")`.
- No alternation (`Count(0 | 1)`), no range (`Count(0..9)`), and no
  binding (`Count(0)#c`): the value is known. Use two transitions or a
  guard, or write the literal where the value is needed.

Types: the head type resolves through newtypes to a base, and the
literal must fit that base (the table in "Comparing values"):

| The head type resolves to | Literal that fits |
|---|---|
| `__int` | integer |
| `__float` | integer, decimal |
| `__text` | string |
| a sum without payloads | none (use the variant) |
| an atomic with no base | none |
| a product, a list, a sum with payloads | none |

Two types with the same base stay different: `Meters(3)` is not
`Seconds(3)`. Equality is by value, so `Meters(3)` and `Meters(3.0)` are
the same.

Where it may appear:

- a source, a pattern in a guard, and an `__init` (`Count(0)`);
- an input head: `setSpeed Speed(0) :: Moving -> Stopped` applies only
  for that input;
- an element key: `Slots[Slot(0)]` is the element with that key (only a
  key type with a base takes a literal);
- a target, as a constant. It sets the value (`Footer(ItemsLeft(1))`)
  and must fit the type. It only narrows "any value" to one value, as a
  variant in a target does. A part left out of a new state stays
  unspecified (see gap 7 in `efsm-gaps.md`).

The checker orders patterns as it does variants. A literal behaves like
a variant of an unbounded sum of its type:

- equal literals are the same pattern; different literals of one type
  are disjoint, so two transitions of one event that differ only in a
  literal source or a literal input do not overlap;
- a literal is inside its bare type, so `Count(0)` against `Count`
  overlaps, as a variant against its sum does;
- literals of different types never relate.

A literal pattern and a guard `c == 0` say the same; both stay, with no
lint. Reachability treats a literal as its bare type. Tracking values
(per type, a finite set of literals or "any"; a warning only when a
source literal is never given to the type) is a later step that needs
the literals in targets and arithmetic in targets.

The printer keeps the literal's spelling. A code generator tests exact
equality for every type: integers, strings character by character with
no normalization, and floats with the target's own float equality.

A named constant (see "Named constants" in `spec-v1.md`) defined as
`Zero = Count(0)` is a pattern equal to `Count(0)`, and one defined as
`GPSFix.Fix3D` is a pattern equal to that variant. As a pattern head it
takes no arguments, and it may appear where the literal pattern may. Today
the checker rejects a constant in a pattern. This comes after literal
patterns exist.

Open:

- Arithmetic in targets, `Count(c + 1)`: see "Arithmetic in targets".

## Arithmetic in targets

Version impact: additive.

A target may compute a value from the values the transition binds:
`Attempts(n + 1)`. It replaces derived values (Part B in `efsm-gaps.md`,
gap 3): the change is written in the transition where it happens, not
in the type definition. Builds on named values (see "Named values" in
`spec-v1.md`) and on "Literal patterns", whose literal in a target is
the simplest case.

    __atomics { Int = __int }

    Attempts = Int

    retry   :: App => Link.Failed * Attempts(Int#n)
                    -> Link.Connecting * Attempts(n + 1)

    connect :: App => Link.Connecting
                    -> Link.Up * Attempts(0)

An expression is built from:

- names the transition binds (`#n` in the input or the source);
- literals, and named constants (`Count(c + Step)`);
- `+`, `-`, `*`, and parentheses.

No division (zero, integer or float?), no function calls, no text
operations.

Types:

- Operands have the same type. A literal fits as in "Comparing values",
  so `n + 1` is an `Int`, and `Meters + Seconds` is an error even though
  both are `__float`. The result has the operands' type.
- It applies to `__int` and `__float`, and to newtypes of them. Not to
  text, to an enumeration, or to an atomic with no base.
- Overflow and rounding are the target's own; the spec promises nothing.

Where an expression goes. Two forms, because a name can be bound to the
inner value or to the whole type:

| Source | Type of the name | Target that uses it |
|---|---|---|
| `Attempts(Int#n)`, or `Attempts(#n)` | `Int`, the wrapped type | `Attempts(n + 1)` |
| `Attempts#attm` | `Attempts`, the whole type | `(attm + 1)` |

- `Head(expr)`: `expr` has the type `Head` wraps, the same rule as
  `Title(e)` with `e : Text`. A name bound to the whole type does not fit
  here (`Attempts(attm + 1)` is an error).
- A parenthesized expression stands where its type is expected, as a
  payload (`Link.Failed(attm + 1)`) or as a factor of a product
  (`Link.Connecting * (attm + 1)`). The checker finds the place by the
  type, and rejects it if two places in the state could take it.
- An expression made only of literals has no type to find, so it needs a
  head: `Attempts(1 + 1)`. A plain literal is a literal pattern
  (`Attempts(0)`).

Parsing:

- After `(`, an uppercase name starts a pattern; a lowercase name, a
  literal, `-` or `(` starts an expression.
- `*` is a product in types and multiplication in expressions. A factor
  that is an expression is parenthesized, and `*` means multiplication
  only inside the parentheses: `Link.Up * (a * 2)` is a product of two
  factors, the second `a * 2`. `Link.Up * a * 2` is an error.
- A bare name as a whole payload (`Typing(t)`) is already a value.

One expression language for targets and guards. Guards compare names
today (`c <= 15`); with it a side may be an expression
(`c + 1 <= max`). That is "Arithmetic in guards" in `TODO.md`.

Gains: no derived-value syntax in type definitions; a counter and its
reset read in two lines (`retry` and `connect` above); the transition
says what changes.

Cost: the checker cannot verify an invariant such as "ItemsLeft is the
number of active todos"; it lives in the transitions, one delta in each.
For reachability, an arithmetic expression makes the type's value "any"
(see "Literal patterns").

Open:

- Division, and `min`/`max`, if a spec needs them.
- Whether an expression is allowed in an `__init` (no names are bound
  there, so only literals and constants, which "Literal patterns" already
  covers).

## Prelude

Version impact: additive.

An optional `.sumspec` file, embedded in the checker and loaded before the
user's spec. It holds the definitions most specs repeat:

    __atomics { Int = __int  Float = __float  Text = __text }

    Bool = True | False

Later it could hold `Ordering` or `Maybe`.

Nothing is reserved. A declaration or definition of the same name in the user's spec
replaces the prelude's, so a spec that needs its own `Text` just defines
it. `Bool` is an ordinary sum, so patterns work on it
(`SingleSideSpraying.True`) and `@control toggle` is a hint over a
two-variant sum. The variants are capitalized, so `@default false` becomes
`@default False`.

## Dependent type

Version impact: additive.

    BoundedList = { xs : [Int] // 2 <= xs.len /\ xs.len <= 10 }

## Guard on data

Version impact: additive.

Guards on patterns and comparisons of values are in v1 (see "Guards" and
"Comparing values" in `spec-v1.md`). What is left:

- **Membership**, `x in ys`: done, see "Membership" in `spec-v1.md`. A form
  for "some element satisfies a comparison" is still open, and so is testing a
  key of a list given as an input (an element path reads the list in the state).
- **Named constants**, such as `BatteryLowThreshold`: done, see "Named
  constants" in `spec-v1.md`.
- **Arithmetic and calls**, such as `a + 1` (see "Arithmetic in
  targets", which defines the expression language) or `further(p, b)`, and
  whether guards share the predicate language of the dependent type
  above.
- Whether a failed guard also shows the control disabled. `@unless` stays
  for the UI ("disabled, with a reason"); a guard is part of the
  transition's meaning.

What it would replace in a real spec (`temp.sumspec`, Parvaz Agro), where
conditions are still encoded as enum states or `@after`:

    -- a derived enum becomes a threshold; the sticky latch stays a state
    batteryLowEvent ... Feed.Live * BatteryCharge#c
      // c <= BatteryLowThreshold
      -> ...

    -- `@after TelemetryAge 60` becomes part of the transition
    linkLossEvent ... Feed.Stale(TelemetryAge#a)
      // a >= 60
      -> AircraftLink.Disconnected

Gains: fewer copies of a transition (`linkLossEvent` has five), fewer
derived-state enums, and rules that were comments become checkable.

### From `@unless`

`@unless P` means "available only while the state does not match `P`",
which is the guard `not P`, with `P` written from the root type. Three
cases:

- A single path on a sum is the complementary variants, as a plain
  positive pattern on the source. No guard is needed, and this is the
  best form because the checker already understands it:

      @unless ...AircraftLink.Disconnected   =>  AircraftLink.Connected
      @unless ...ArmState.Armed              =>  ArmState.Disarmed
      @unless ...BatteryReserve.Low          =>  BatteryReserve.Enough
      @unless ...GPSFix.{NoFix | Fix2D}      =>  GPSFix.{Fix3D | DGPS | RTKFix}

  So a guard is not needed where a variant pattern says it:

      goToAircraft
        :: App
        => Page.Home * AircraftLink.Connected
        -> Page.Plan(PMode.ManualAircraft)

- Several `@unless` lines are an AND: each forbids one thing, so the
  transition needs all of them false (`not a and not b`), or all the
  positive patterns at once. The six lines of `startMission` collapse
  into its source.
- A compound `@unless (X * Y)` is `not (X and Y)`, which is
  `not X or not Y`. A source pattern cannot say "or" across two parts of
  the state, so it needs a guard, or two transitions:

      pagePlanBackToHome :: App => Page.Plan
        // not ( Page.Plan(PMode.ManualAircraft)
               and AircraftLink.Connected(Aircraft(AircraftStatus(ArmState.Armed))) )
        -> Page.Home

The "reason" text is lost in the conversion: a guard only blocks. So
`@unless` stays where the UI must say why a control is disabled; the
target can derive the reason from the unmet pattern or guard. A checker
lint could flag an `@unless` that a source pattern expresses.

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

## Naming an element

Version impact: additive.

    rename TodoId#id :: Todos[id]#t -> ...

`L[x]#t` names the element, with the element type (`Todo`), not the
list type. Not allowed yet.

## Branches on a guard

Version impact: additive.

Builds on branches (see "Branches" under "Shared path" in `spec-v1.md`).
Several conditions on one source, with the source written once and one
`//` per branch:

    f :: T(Int#i)
      // i <  10 -> ...
      // i >= 10 -> ...

Means:

    f :: T(Int#i) // i <  10 -> ...
      :: T(Int#i) // i >= 10 -> ...

It's for a long source that only a condition splits. A split on variants
is a branch on a shared path, which can also bind values:

    toggleTodo TodoId#id
      :: Todos[id]
      => Completion.Active -> Completion.Completed
      => Completion.Completed -> Completion.Active

Rules:

- Each branch is a transition with the shared source and its own guard.
  The checker works on the expanded transitions, so overlap needs nothing
  new: `i < 10` and `i < 20` warn.
- A branch binds nothing, as every guard: `// Mode.Editing(#t) -> ...`
  stays an error. Bind on the source, or use branches on a shared path.
- Branches have no order: it reads like a `case`, but the first branch
  that holds doesn't win, and overlapping branches warn.
- Nothing checks that the branches cover every case. When none holds,
  the event doesn't apply, as with any guard.
- No `otherwise` branch: it would depend on the other branches, so a
  branch would no longer be one transition.

Open:

- How it combines with branches on a shared path
  (`:: App => Src // g -> T // h -> U => ...`), and its canonical layout.
- A factor shared by branches, such as
  `AircraftLink.Connected(Aircraft(Feed.Stale))` in every source of
  `linkLossEvent`: `/` can't hold it, since it sits beside `Page`, not
  around it.
