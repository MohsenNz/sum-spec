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

## `@` annotation

Version impact: additive.

An annotation is metadata: something the application needs that the
types can't say (how a value is drawn, when a transition is unavailable,
which side effect a transition causes). SumSpec gives it no meaning; the
target (the code generator) does.

An annotation is `@name` followed by its arguments, which the checker
treats as opaque. Available annotations are declared once, in a header
block like `__events`; only declared names may be used. A comment next to
each name documents it:

    __annotations {
      @control     -- what widget edits a value or triggers an action
      @unless      -- a transition is unavailable while this state holds
      @effect      -- a side effect the transition causes
    }

An annotation goes after the head of a type definition, after the
variant or member it belongs to, or on the lines after a transition.
Several may be stacked:

    Draft @default Empty = Empty | Typing Text @control text_field

    exportLogs :: Page.Logs -> Page.Logs
      @control button_icon
      @effect share Logs

In a newtype `A = B @x`, the annotation belongs to `A`; in a sum or a
product it belongs to the variant or member it follows.

SumSpec has no event outputs (see `efsm-gaps.md`, section 4): a side
effect is an annotation on the transition, such as `@effect`.

The checker verifies that every name is declared in `__annotations` and
declared once. Checking arguments is open: opaque tokens first, then
arguments that are state paths (`@unless`, `@when`) read as patterns.

A declaration may state its argument kind, so the checker validates it:

    __annotations {
      @unless <pattern>   -- unavailable while this state holds
      @when   <pattern>
      @control <name>
    }

For a `<pattern>` argument the checker can resolve every name against the
types, and warn when the pattern can never hold, always holds, or
contradicts the transition's source (`@unless Page.Home` on a transition
from `Page.Home`).

A type the notation does not decompose and that has no base type in the
language is declared inside __atomics. An atomic has no members here; each
target supplies it, and the only thing the checker knows about its values
is equality. An atomic with a base (`Port = __int`) is described under
"Primitive types" in `spec-v1.md`. An atomic takes no annotations: a type
that needs `@default` or `@range` is a newtype of it.

## Checking `@default` and `@range`

Version impact: additive.

Builds on the primitive types and the comparisons of v1 (see "Primitive
types" and "Comparing values" in `spec-v1.md`), and on the annotations
above. A newtype over an atomic carries the annotations, since an atomic
takes none:

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
      @unless ...GPSFix(NoFix | Fix2D)       =>  GPSFix(Fix3D | DGPS | RTKFix)

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

## Alternatives in a pattern

Version impact: additive.

`Sum(A | B)` says "the sum is one of these variants". It's for a source
that applies to some variants of a sum but not all, which today takes one
transition per variant:

    linkLossEvent
      :: App
      => Page(Home | Devices | Logs)
       * AircraftLink.Connected(Aircraft(Feed.Stale))
      -> AircraftLink.Disconnected

An alternative is a variant of the sum, without the sum's name, and may
have arguments, which may hold alternatives of their own:

    MissionFlight(Arming | Failed
      | Flying(FPhase(Approaching | Holding | Returning | PilotControl)))

Gains: `linkLossEvent` in `temp.sumspec` is five transitions with
alternatives and fourteen without. The conversion of `@unless` under
"Guard on data" also needs it (`GPSFix(Fix3D | DGPS | RTKFix)`).

Syntax:

- Inside the parentheses after a sum, two or more alternatives separated
  by `|`. `Page(Home)` stays an error: write `Page.Home`.
- Nothing else goes at that level: `Page(Home | Logs * Link.On)` is an
  error. A factor beside it goes outside the parentheses, as in the
  example above.
- `|` in a pattern is a syntax error today, and a sum with arguments is a
  type error, so no spec changes meaning.

Sketch of the grammar: `type_pattern` gets one more form of argument.

    alternatives  = alternative , "|" , alternative , { "|" , alternative } ;
    alternative   = UPPER , [ "(" , ( NAMING | pattern , { "*" , pattern }
                                    | alternatives ) , ")" ] ;

Meaning: a source with alternatives is one transition per alternative,
with the same target. In a guard, `G(A | B)` means `G.A or G.B`. The
checker works on the expanded transitions, so overlap, reachability and
"can never happen" need nothing new. With alternatives in two parts of a
source, the expansion takes every combination.

Rules:

- The head resolves to a sum, and each alternative is a variant of it,
  written once. An unknown or repeated variant is an error. Arguments
  must fit the variant, as in "Arguments in state patterns".
- Only in a source and in a pattern in a guard. Not in a target (it sets
  one state) or in an `__init`, an input or a shared path.
- The target must be valid for every alternative. A part keeps its value
  only where the source fixes the same variants along its path, and each
  alternative is read on its own. An error found in several alternatives
  is reported once.
- No names inside alternatives: `Mode(Editing(#t) | Viewing)` is an error,
  because `t` has no value in `Viewing`. Write two transitions.
- Variants only: `Count(0 | 1)` stays out, as in "Literal patterns".

Open:

- A name bound in every alternative with one type
  (`Mode(Editing(#t) | Reviewing(#t))`), if a spec needs it.
- A way to name a set of variants once, if the same alternatives repeat
  across events.

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
