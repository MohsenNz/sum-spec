# Gaps between SumSpec and an EFSM

SumSpec 1.0 reads as a nondeterministic, hierarchical Extended
Finite-State Machine (EFSM). Two differences are deliberate and stay:

- The state is one algebraic data type, so the data that exists depends
  on the variant (`Screen.NoTodos` has no `Todos`).
- Sums are OR-states and products are AND-states (orthogonal regions),
  as in statecharts.

The gaps below make a spec less precise than an EFSM. Each one is to be
addressed on its own: decide on a design, then move it to
`proposals.md` (or straight into the spec) with its version impact. None
of them is part of v1.

An EFSM transition, for reference:

    s --[ event(params) / guard(V, params) / V := update(V, params) / output ]--> s'

## 1. Where a local transition applies

Status: decided in part; continues after 3.

A transition written on a sub-type applies wherever that type occurs:

    toggleTodo :: Completion.Active -> Completion.Completed

`Completion` is inside every `Todo` of `Todos = [Todo]`. The spec doesn't
say whether `toggleTodo` changes one todo or all of them, or which one.
An EFSM transition acts on the whole state, and an event parameter (an
index or id) picks the element.

Decision: keep local transitions. Forbidding them would leave
transitions on a list element, like `toggleTodo`, with no way to be
written in v1 (a pattern can't reach into one element of `[T]`), and
every pattern would repeat the path from `App`. Locality is also what
the statechart reading (sums as OR-states, products as AND-states)
relies on.

Rules:

1. A local transition changes exactly one occurrence of its type, never
   all of them.
2. Inside a list, the element is picked by comparing its key with a
   named input; without that, which element changes isn't said. Decided
   in 1.1; see "Keys" under "Named values" in `spec-v1.md`:

       toggleTodo TodoId#id :: Todo(id * Completion.Active) -> Todo(Completion.Completed)

3. The checker rejects a local transition whose type occurs at more than
   one place of `App` that isn't the same list. Such a transition is
   written from a common ancestor that tells the places apart.

Open, after 3: effects outside the transition's type. `toggleTodo`
changes a `Completion`, but `ItemsLeft` and `ToggleAll` must change too,
and a local transition can't reach them. Preferred: declare them as
derived values (see 3), so no transition updates them. Otherwise, a
transition that changes parts outside its type is written from an
ancestor that holds them.

## 2. Guards on data

Status: open.

A source pattern only matches variants. It can't state a predicate on
data, such as `ItemsLeft > 0`, `Title` not empty, or "this is the last
todo".

To decide:

- The form of a guard and where it goes (after the source pattern, as an
  annotation, as a refined type).
- Which predicates are allowed on atomics, whose meaning the spec
  doesn't define (comparison, emptiness, list length).
- Related: "Dependent type" in `proposals.md` refines types, not
  transitions.

## 3. Updates say what changes, not how

Status: Part A (named values) decided, in 1.1 (see "Named values" in
`spec-v1.md`); Parts B and C open.

`Todos'` says the todos get a new value. It doesn't say a todo was added,
removed or edited, or how `ItemsLeft'` relates to `Todos'`. An EFSM's
update is a function of the old values and the inputs.

To decide:

- Whether to describe updates at all, or a fixed set of them (append,
  remove, set to an input, increment).
- How an update refers to old values, new values and inputs.
- Derived values: `ItemsLeft` is the number of active todos. Saying so
  once (an invariant) may replace updating it in every transition.

Proposal, in three parts. No arithmetic: atomics stay opaque, and
everything is about structure (variants, lists, keys, named values).

**Part A, named values (done, 1.1).** `P#x` names a value in the input
or on the source side; `x` uses it. On the source side a name is an
equality guard, on the target side it sets the value. Newtypes are
strict: `EditText(Text#e)` then `Title(e)`.

**Part B, derived values (open).** A part computed from others, which
transitions read but never write:

    ItemsLeft = Count := count Todos where Todo(Completion.Active)
    ToggleAll = NotAllDone | AllDone
      := AllDone if all Todos are Todo(Completion.Completed) else NotAllDone

Patterns are the predicates: `count ... where P`, `all ... are P`,
`any ... are P`, `empty ...`. The same vocabulary can serve gaps 2 and 5
as guards.

**Part C, list updates (open).**

| Form | Meaning |
|---|---|
| `L += P` | add an element built by `P` |
| `L -= x` | remove the element whose key is `x` |
| `L -= where P` | remove every element that matches `P` |
| `L each P` | apply `P` to every element (`toggleAll`) |

Open questions for B and C:

- Derivations on the type definition, or in a `__derived { }` block; the
  keywords (`:=`, `if`, `else`, `are`, `where`).
- How a derivation finds its sources (the nearest product holding both).
- Fresh keys: `TodoId'` in `+=`, or a `fresh` keyword.
- A list in a new state (`addTodo` from `Screen.NoTodos`): a list literal,
  or "a new list starts empty".
- The syntax of `+=`, `-=` and `each`.

## 4. Event inputs and outputs

Status: inputs decided, in 1.1 (see "Transition inputs" in
`spec-v1.md`); outputs open.

A transition is only a name. It takes no input, so the typed text in
`NewTodo.Typing(Text)` appears only as "Text has some value". It
produces no output, such as a message to the user or a call to a
device.

To decide:

- Inputs (done): `f X :: A -> B`. Every signature of a transition takes
  the same input, as an EFSM event has one parameter list. How the
  target says "this part is set to the input" is part of 3.
- Outputs: whether a transition can emit an event or effect, and its
  type.

## 5. Nondeterminism between signatures

Status: open.

Two signatures of one transition may share a source:

    deleteTodo :: Screen.WithTodos -> Screen.WithTodos(Todos' * ToggleAll' * Footer')
    deleteTodo :: Screen.WithTodos -> Screen.NoTodos

Which one applies depends on data the spec doesn't express (whether the
deleted todo was the last). An EFSM separates them with guards.

To decide:

- Whether overlapping sources must carry guards that exclude each other
  (depends on 2), or whether nondeterminism stays allowed and is marked.
- Related: the "transitions whose signatures overlap" warning in
  `TODO.md`.

## 6. Initial state

Status: open.

`App` is the type of every state, not the state the app starts in. An
EFSM has an initial control state and initial values for its variables.

To decide:

- A syntax for the initial state (for example a pattern for `App`, or a
  transition with no source).
- What a part that's left out means there: any value, or an empty value
  for lists.
- With an initial state, the checker can warn about states no
  transition reaches (already an open question in `TODO.md`).

## 7. Values inside a new state

Status: open.

Inside a new state, a part that's left out may have any value:

    goToPlan :: Page.Home -> Page.Plan(PMode.JustMap)

`Missions` may be anything here. An EFSM assigns every variable on every
transition.

To decide:

- Whether a new state must give every part (a variant, a primed part, or
  a default), or whether "any value" stays and is written explicitly.
- Whether types can declare a default value (empty list, a variant)
  used when a new state leaves a part out. This ties in with 6.
