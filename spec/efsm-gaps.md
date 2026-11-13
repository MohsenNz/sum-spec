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
every pattern would repeat the path from the root. Locality is also what
the statechart reading (sums as OR-states, products as AND-states)
relies on.

Rules:

1. A local transition changes exactly one occurrence of its type, never
   all of them. An element path over several elements (`L[each #x in xs]`
   in `spec-v1.md`) changes each listed element instead.
2. Inside a list, the element is picked by comparing its key with a
   named input; without that, which element changes isn't said.
   Decided; see "Keys" under "Named values" in `spec-v1.md`:

       toggleTodo TodoId#id :: Todo(id * Completion.Active) -> Todo(Completion.Completed)

   The checker warns about a transition inside a list element that
   doesn't pick the element. Nested lists, where a key written from
   the element can't pick an element of an outer list: decided,
   with keyed lists (`Todos = [Todo by TodoId]`) and element paths
   (`Projects[p](Todos[t](...))`); see "Keyed lists" and "Element
   paths" in `spec-v1.md`.

3. The checker rejects a local transition whose type occurs at more than
   one place of the root that isn't the same list. Such a transition is
   written from a common ancestor that tells the places apart.

Open, after 3: effects outside the transition's type. `toggleTodo`
changes a `Completion`, but `ItemsLeft` and `ToggleAll` must change too,
and a local transition can't reach them. Derived values (see 3) were
the preferred answer but were replaced; now a transition that changes
parts outside its type is written from an ancestor that holds them, and
sets them with a literal or an arithmetic expression (gap 7).

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

Status: Part A (named values) decided (see "Named values" in
`spec-v1.md`); Part B replaced by arithmetic in targets, now in v1 (see
"Computed values" in `spec-v1.md`); Part C open.

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

**Part A, named values (done).** `P#x` names a value in the input
or on the source side; `x` uses it. On the source side a name is an
equality guard, on the target side it sets the value. Newtypes are
strict: `EditText(Text#e)` then `Title(e)`.

**Part B, derived values (replaced).** Replaced by arithmetic in targets
(`Count(c + 1)`, see gap 7 and `literal-patterns.md`, question 13): a
change is written in the transition where it happens, not in the type
definition. The text below is kept as the design that was not chosen.

A part computed from others, which transitions read but never write:

    ItemsLeft = Count := count Todos where Todo(Completion.Active)
    ToggleAll = NotAllDone | AllDone
      := AllDone if all Todos are Todo(Completion.Completed) else NotAllDone

Patterns are the predicates: `count ... where P`, `all ... are P`,
`any ... are P`, `empty ...`. The same vocabulary can serve gaps 2 and 5
as guards. `efsm-derived-values.md` shows how an EFSM handles derived
values, with the TodoMVC example and the syntax under discussion.

**Part C, list updates (open; form chosen).** An action clause, between
the source and the target, says how a value changes, like an EFSM's
`event / update`:

    deleteTodo TodoId#id
      :: Screen.WithTodos(Todos#ts)
      ~> __remove ts[id]
      -> Screen.WithTodos(ToggleAll' * Footer')

- An action works on a named value from the source (`ts`). `ts[id]` is
  the element whose key is `id`, as in "Element paths" in
  `spec-v1.md`.
- A part changed by an action isn't primed or set in the target: the
  action is the only place that says how it changes (`Todos'` is gone
  above).
- Actions are builtins, named with the `__` prefix like `__events`:

| Action | Meaning |
|---|---|
| `__add ts P` | add an element built by `P` |
| `__remove ts[x]` | remove the element whose key is `x` |
| `__remove ts where P` | remove every element that matches `P` |
| `__each ts P` | apply `P` to every element (`toggleAll`) |

`__each` is in v1 as an element path: `L[each] => P` applies `P` to every
element that matches its source (see "Every element that matches" in
`spec-v1.md`).

The action doesn't make the second transition of `deleteTodo` (to
`Screen.NoTodos` when the last todo goes) or `ToggleAll'` and `Footer'`
go away; with Part B replaced, the transition writes them (gap 7).

Open questions for C (the questions about derivations went with Part B):

- Fresh keys: with a keyed list (`Todos = [Todo by TodoId]`),
  the key belongs to the list, so `__add` can make it. To decide:
  whether the new key can be named, for a target that uses it.
- A list in a new state (`addTodo` from `Screen.NoTodos`): a list literal,
  or "a new list starts empty".
- The separator: `//` is already "such that" in the "Dependent type"
  proposal; `/` (as in an EFSM) or a keyword are the alternatives.
- One action per transition, or several (`toggleAll` may need `__each`
  together with others).
- Which names an action may use: the source's, the input's (`__add ts
  Todo(Title(t) * ...)` for `addTodo`), or both.
- Where the action clause goes in a transition written on one line.

## 4. Event inputs and outputs

Status: inputs decided (see "Event inputs" in
`spec-v1.md`); outputs decided: not in the language.

An event is only a name. It takes no input, so the typed text in
`NewTodo.Typing(Text)` appears only as "Text has some value". It
produces no output, such as a message to the user or a call to a
device.

To decide:

- Inputs (done): `f X :: A -> B`. The input is written once, after the
  event's name, as an EFSM event has one parameter list. How the
  target says "this part is set to the input" is part of 3.
- Outputs (decided: none): a transition does not emit events or
  effects. SumSpec describes the states and how they change, not how
  the app touches the world, so effects are left to the generator.
  - The state change already implies most effects (`Form.Saving` says
    a save is in progress), and a response is an ordinary event
    (`saved`, `failed`).
  - What the types can't say (which API, a debounce) is metadata, so
    it goes in an annotation on the transition (see "Annotations
    (@name)" in `spec-v1.md`), not in a second, typed mechanism.
  - Considered and dropped: an `__effects` block with typed payloads
    and a `! effect(x)` clause on transitions. It adds checking
    (payload types, every effect emitted) at the cost of a block, a
    clause and more rules, which a spec read by an AI agent doesn't
    need. Reopen it only if annotations prove too weak.

## 5. Nondeterminism between transitions

Status: open.

Two transitions of one event may share a source:

    deleteTodo :: Screen.WithTodos -> Screen.WithTodos(Todos' * ToggleAll' * Footer')
               :: Screen.WithTodos -> Screen.NoTodos

Which one applies depends on data the spec doesn't express (whether the
deleted todo was the last). An EFSM separates them with guards.

To decide:

- Chosen direction, once guards exist (2): the transitions of an event
  are tried in order, and the first whose source matches applies (as in
  a Haskell `case`). The checker then warns about a transition an
  earlier one covers, as it can never apply. Transitions on different
  types still all happen (`commit` in `example/git.sumspec`). Not before
  guards: every overlap in the examples has identical sources
  (`deleteTodo`, `clearCompleted`), so the second transition of each
  would never apply. `example/git.sumspec` makes each outcome its own
  event instead: `merge` and `mergeConflicted` (decided outside the
  model), `rebaseContinue` and `rebaseFinished` (until a guard can test
  that a list is empty). The transitions of an
  event are already written together, in order (see "Several
  transitions for one event" in `spec-v1.md`).
- The checker already warns about two transitions of one event, on
  the same type, whose sources can match the same state (see "Several
  transitions for one event" in `spec-v1.md`).

## 6. Initial state

Status: decided (see "Initial state" in `spec-v1.md`).

An EFSM has an initial control state and initial values for its
variables. `App` used to be the type of every state, not the state the
app starts in.

Decision: `__init :: P`, written once. `P` is the initial state, and its
head type is the root, the type of every state, so `App` is an ordinary
name. `P` is a whole new state: a part left out may have any value (gap
7), and nothing in it takes a prime, a name or an element path.

Still open:

- Empty values: whether a list left out of `__init` starts empty
  (ties in with 7).
- The checker warns about variants the app never reaches, from
  `__init` (see "Initial state" in `spec-v1.md`).

## 7. Values inside a new state

Status: decided in part. Literals, constants and arithmetic in targets
and `__init` are in v1 (see "Computed values" in `spec-v1.md`); the
warning below is still open.

Inside a new state, a part that's left out may have any value:

    goToPlan :: Page.Home -> Page.Plan(PMode.JustMap)

`Missions` may be anything here. An EFSM assigns every variable on every
transition.

Decision:

- **"Any value" stays.** A new state need not give every part, and a part
  it leaves out is unspecified. The same holds for `__init`, which is a
  new state too (gap 6).
- **No defaults on types.** The language does not depend on annotations
  (`@default` is not type-checked), and types declare no default value.
  Where a value matters, the transition writes it.
- **A literal in a target sets the value**, as a constant that fits its
  type: `Footer(ItemsLeft(1))`. It only narrows "any value" to one value,
  as a variant in a target already does. It also works in `__init`
  (`Count(0)`).
- **Computed values are arithmetic in the target**, `Count(c + 1)`, over
  names the transition binds. This replaces derived values (gap 3,
  Part B): the change is written where it happens, not in the type
  definition. Cost: an invariant such as "ItemsLeft is the number of
  active todos" lives in the transitions and the checker can't verify it.

Still open:

- Whether the checker warns about a part a new state leaves out when
  nothing later sets it.
