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

It builds on `=>`, which is in v1 (see "Shared path" in `spec-v1.md`):

    X => Y => A' * B' <-

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

- **Membership**, `e in ms`: a named value is an element of a named list
  value. It needs the element type of a list value, and a rule for what is
  compared when the list holds products (`EdgeMargins` holds `Edge *
  EdgeInset`, and `Edge` is only a part of an element).

      edgeMarginReset ... EdgePick.Selected(Edge#e) * EdgeMargins#ms
        // e in ms
        -> ...

- **`matches`**, `x matches P`: does a named value match a pattern. A
  source pattern already says it for the part it names, so it is only
  needed to test a value after it has been named elsewhere.
- **Named constants**, such as `BatteryLowThreshold`: a type holding a
  value by `@default`, usable as a side of a comparison. It needs
  annotations.
- **Arithmetic and calls**, such as `a + 1` or `further(p, b)`, and
  whether guards share the predicate language of the dependent type
  below.
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
