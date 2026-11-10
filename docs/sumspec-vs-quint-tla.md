# SumSpec vs Quint and TLA+

How SumSpec relates to formal specification languages, TLA+ and Quint
in particular. It covers what they share, where they differ, and why
SumSpec exists alongside them.

## In short

All three model a system as **state plus transitions**: types or
variables for the state, an initial state, and guarded events that move
between states.

- **TLA+ and Quint** are verification languages. You state properties
  (invariants, "eventually" claims) and a model checker explores every
  reachable state to check them.
- **SumSpec** is a design language. It describes what an application
  is (its screens, state shapes and events) compactly enough for a
  human to approve and for an AI to generate code from. It checks that
  the spec is well formed, not that properties hold.

SumSpec is a **lightweight formal specification language**: formal
enough to type-check, and readable enough to approve.

## The same drone in each

A drone that takes off with enough battery, flies until the battery is
low, returns, lands and charges.

### TLA+

TLA+ is mathematical notation in plain text. `/\` is and, `\/` is or,
and `x'` is the value of `x` in the next state.

```tla
---- MODULE Drone ----
EXTENDS Naturals
VARIABLES mode, battery
vars == <<mode, battery>>

TypeOK == mode \in {"Grounded", "Flying", "Returning"} /\ battery \in 0..100

Init == mode = "Grounded" /\ battery = 100

TakeOff    == /\ mode = "Grounded" /\ battery > 20
              /\ mode' = "Flying"  /\ UNCHANGED battery
Fly        == /\ mode = "Flying" /\ battery >= 15
              /\ battery' = battery - 1 /\ UNCHANGED mode
LowBattery == /\ mode = "Flying" /\ battery < 15
              /\ mode' = "Returning" /\ UNCHANGED battery
Land       == /\ mode = "Returning"
              /\ mode' = "Grounded" /\ UNCHANGED battery
Charge     == /\ mode = "Grounded" /\ battery < 100
              /\ battery' = battery + 1 /\ UNCHANGED mode

Next == TakeOff \/ Fly \/ LowBattery \/ Land \/ Charge

Spec == Init /\ [][Next]_vars /\ WF_vars(LowBattery) /\ WF_vars(Land)

NeverEmptyInFlight == mode = "Flying" => battery > 0          \* safety
ReturnsHome == (mode = "Returning") ~> (mode = "Grounded")    \* liveness
====
```

You check it with the TLC model checker, using a config file:

```
SPECIFICATION Spec
INVARIANT TypeOK NeverEmptyInFlight
PROPERTY ReturnsHome
```

If a property fails, TLC prints a counterexample: the sequence of steps
that breaks it.

### Quint

Quint gives TLA+'s semantics a typed syntax that reads like TypeScript.
Inside an action, `all { ... }` means and, and `any { ... }` means or.
Each action assigns every variable.

```quint
module drone {
  type Mode = Grounded | Flying | Returning

  var mode: Mode
  var battery: int

  action init = all { mode' = Grounded, battery' = 100 }

  action takeOff = all {
    mode == Grounded, battery > 20,
    mode' = Flying, battery' = battery,
  }
  action fly = all {
    mode == Flying, battery >= 15,
    mode' = mode, battery' = battery - 1,
  }
  action lowBattery = all {
    mode == Flying, battery < 15,
    mode' = Returning, battery' = battery,
  }
  action land = all {
    mode == Returning,
    mode' = Grounded, battery' = battery,
  }
  action charge = all {
    mode == Grounded, battery < 100,
    mode' = mode, battery' = battery + 1,
  }

  action step = any { takeOff, fly, lowBattery, land, charge }

  val neverEmptyInFlight = mode == Flying implies battery > 0
  temporal returnsHome =
    always(mode == Returning implies eventually(mode == Grounded))

  run takeOffTest = init.then(takeOff).expect(mode == Flying)
}
```

```
quint typecheck drone.qnt
quint run drone.qnt --invariant=neverEmptyInFlight     # random simulation
quint verify drone.qnt --invariant=neverEmptyInFlight  # exhaustive, via Apalache
quint test drone.qnt
```

Quint also has sum types with payloads (`Detail(str)`), records,
`match`, maps and sets, and inputs chosen by `nondet`. Its tooling
includes a REPL, an LSP and a VS Code extension.

### SumSpec

```haskell
__atomics {
  Battery = __int  -- percent, 0 to 100
}

__events {
  takeOff
  fly          -- the drone reports its new charge
  lowBattery
  land
  charge       -- the charger reports the new charge
}

__init :: Drone(Mode.Grounded)

Drone = Mode * Battery

Mode = Grounded | Flying | Returning

takeOff    :: Drone => Mode.Grounded * Battery#b // b > 20  -> Mode.Flying
fly        :: Drone => Mode.Flying   * Battery#b // b >= 15 -> Battery'
lowBattery :: Drone => Mode.Flying   * Battery#b // b < 15  -> Mode.Returning
land       :: Drone => Mode.Returning -> Mode.Grounded
charge     :: Drone => Mode.Grounded * Battery#b // b < 100 -> Battery'
```

`sumspec check` accepts it. A target names only what changes: the rest
of the state stays as it was. `Battery'` means Battery has a new value.
The spec says *that* the value changes, not *how*, because SumSpec has
no arithmetic yet. There are no properties to state.

## Side by side

| | TLA+ | Quint | SumSpec |
|---|---|---|---|
| State | Untyped `VARIABLES` plus a `TypeOK` invariant | Typed `var`s | One typed state tree (`Drone = Mode * Battery`) |
| Enumerations | Sets of strings | Sum types | Sum types |
| Nested state | Records and functions | Records, sums, `match` | Sums and products, reached by paths (`Screen.Detail`) |
| Initial state | `Init` | `action init` | `__init` |
| Transition | An action: guard `/\` update | An action: guards and an assignment for every variable | `event :: source // guard -> target` |
| Unchanged state | `UNCHANGED x` | Assigned explicitly | Implicit |
| Event inputs | `\E x \in S : A(x)` | `nondet x = S.oneOf()` | Event inputs (`label Name#n :: ...`) |
| Logic | Full set theory and arithmetic | Expressions, maps, sets, folds, lambdas | Patterns, comparisons, membership |
| Properties | Invariants, temporal logic | Invariants, temporal properties, tests | None |
| Checking | TLC, Apalache, TLAPS proofs | Simulator, Apalache, tests | Type checker, reachability and overlap warnings |
| Metadata for code | None | None | Annotations (`@control button`) |
| Tooling | TLA+ Toolbox, VS Code extension | REPL, LSP, VS Code extension | CLI checker (LSP planned: `docs/lsp.md`) |
| Main reader | An engineer verifying a design | An engineer verifying a protocol | A human approving a design, and an AI building the app |

The family also includes:
- **Event-B**, whose events with guards and actions are the closest to
  SumSpec's transitions;
- **Alloy**, which is closest in spirit: "lightweight formal methods";
- **Statecharts**, for nested state.

## Why SumSpec exists alongside Quint

**A different question.** Quint asks: "Is this protocol correct under
every interleaving?" SumSpec asks: "What is this application?" Quint's
users write invariants and run a model checker. SumSpec's users read and
approve a design, and an AI builds it.

**App state is a deep tree.** An application is nested sums with
payloads (`Page.Plan(PMode.ShowMission.List)`). Quint keeps state in
flat variables, with a `match` and a primed assignment for every
variable in each action, so a UI with 40 transitions becomes long and
noisy. Two features keep a SumSpec spec short enough to review:
- path patterns (`Screen.Home -> Screen.Busy`);
- the implicit "what isn't changed stays the same".

**Approvability.** Someone who isn't an engineer can read
`Mode = Grounded | Flying | Returning` and
`takeOff :: Mode.Grounded -> Mode.Flying`. They won't read
`all { mode == Grounded, ..., battery' = battery }`.

**Code generation.** Annotations, the planned core and UI specs
(`spec/proposals.md`), and a small, closed set of constructs map
directly onto UI architectures (TEA, Redux, SwiftUI). A language with
one way to say each thing is easier for an AI to translate faithfully.

## Risks

- **Nicer syntax alone isn't enough.** SumSpec's case rests on what
  Quint can't say compactly: nested-state paths, the implicit frame,
  annotations, and core and UI specs. Keep those central.
- **Tooling is expensive.** Quint already has its checker, LSP and
  editor support. SumSpec has to build its own, so stay small.
- **The pull toward verification.** Invariants, rich arithmetic and
  temporal logic move SumSpec onto Quint's ground, where it would be a
  weaker copy. Guards and arithmetic for describing an app are fine;
  stop before proofs.
- **AI familiarity.** Models have seen TLA+ and some Quint, but no
  SumSpec. The language is small, though, so the spec and `spec-v1.md`
  fit in context.

## Position: a complement, not a rival

SumSpec is the design layer that people read and approve. Quint is
where the design gets verified, when that's needed.

- **Non-goal.** SumSpec doesn't do model checking or proofs.
- **Export to Quint (future).** Once a resolved model exists
  (`SumSpec.Model`, see `docs/lsp.md`), translate it as follows:
  - sums become Quint sums;
  - products become records;
  - each transition becomes an action, with the unchanged state filled
    in;
  - `__init` becomes `init`.

  Users then write invariants in Quint, and get simulation and model
  checking without SumSpec building any of it.
- **Properties as annotations (maybe).** `@invariant ...` or
  `@eventually ...` with opaque arguments, passed through to the
  export.

## An experiment to run

Write `example/drone.sumspec` in Quint by hand. Then compare:
- the length;
- the number of places that repeat unchanged state;
- how quickly someone who isn't an engineer can say what the app does.

If Quint comes out close, rethink SumSpec's case. If SumSpec is several
times shorter, which is the expectation for UI-heavy specs, the
comparison is strong evidence for the README and for promotion (see
`docs/promotion.md`).
