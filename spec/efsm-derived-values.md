# Derived values in an EFSM

Background for gap 3, Part B ("derived values") in `efsm-gaps.md`. It
shows how an EFSM handles a value computed from other state, such as
TodoMVC's items-left count, and how that maps onto SumSpec. Not part of
v1.

An EFSM has no derived values. It has control states, variables, and
transitions of the form `event [guard] / update`. A value like "items
left" can be handled in one of two ways, which correspond to SumSpec's
primes and to the proposed `:=`.

## The EFSM for TodoMVC

- Control states: `NoTodos`, `WithTodos`.
- Variables: `todos : list of (id, title, done)`.
- Inputs: `addTodo(text)`, `toggle(id)`, `toggleAll`, `delete(id)`, ...

## Option 1: a variable, updated by every transition

Add the variables `itemsLeft : Nat` and `allDone : Bool`. Each
transition's update must keep them correct:

```
NoTodos   --addTodo(text) / todos := [(new, text, false)];
                            itemsLeft := 1; allDone := false            --> WithTodos

WithTodos --addTodo(text) / todos := todos ++ [(new, text, false)];
                            itemsLeft := itemsLeft + 1; allDone := false --> WithTodos

WithTodos --toggle(id) [¬todos[id].done]
                         / todos[id].done := true;
                           itemsLeft := itemsLeft - 1;
                           allDone := (itemsLeft = 0)                   --> WithTodos

WithTodos --toggle(id) [todos[id].done]
                         / todos[id].done := false;
                           itemsLeft := itemsLeft + 1; allDone := false --> WithTodos

WithTodos --delete(id) [|todos| > 1]
                         / if ¬todos[id].done then itemsLeft := itemsLeft - 1;
                           todos := todos - id;
                           allDone := (itemsLeft = 0)                   --> WithTodos

WithTodos --delete(id) [|todos| = 1] / todos := []                      --> NoTodos
```

This is what SumSpec does today with `ItemsLeft'` and `ToggleAll'`,
except that SumSpec doesn't say how the value changes. The EFSM is more
precise, but has the same weakness: the invariant `itemsLeft = number of
undone todos` holds only if every transition maintains it. One forgotten
update makes the model wrong.

## Option 2: a function of the variables, never stored

```
itemsLeft(v)      = |{ t ∈ v.todos | ¬t.done }|
allDone(v)        = ∀ t ∈ v.todos. t.done
showClearDone(v)  = ∃ t ∈ v.todos. t.done
```

The transitions update only `todos`:

```
WithTodos --toggle(id) [¬todos[id].done] / todos[id].done := true   --> WithTodos
WithTodos --toggle(id) [todos[id].done]  / todos[id].done := false  --> WithTodos

WithTodos --toggleAll [allDone(v)]  / ∀t ∈ todos. t.done := false   --> WithTodos
WithTodos --toggleAll [¬allDone(v)] / ∀t ∈ todos. t.done := true    --> WithTodos

WithTodos --delete(id) [|todos| > 1] / todos := todos - id          --> WithTodos
WithTodos --delete(id) [|todos| = 1] / todos := []                  --> NoTodos
```

The functions are read in guards (`toggleAll [allDone(v)]`) and in
outputs (the footer shows `itemsLeft(v)`), and never assigned. Formally
they are observers, or the output functions of a Moore-style machine,
not part of the state.

## In SumSpec

The proposed syntax for Part B is Option 2. A derivation is written on
the product that holds its sources, at any depth below it, and a factor
may refine a named type with a partial product (`Footer( ... )`):

```
Screen
  = NoTodos
  | WithTodos
      ( Todos#ts
      * ToggleAll := AllDone if all ts are Todo(Completion.Completed) else NotAllDone
      * Footer
          ( ItemsLeft := count ts where Todo(Completion.Active)
          * ClearCompleted := Shown if any ts are Todo(Completion.Completed) else Hidden
          )
      )
```

| EFSM | SumSpec |
|---|---|
| `itemsLeft(v) = \|{t ∈ todos \| ¬t.done}\|` | `ItemsLeft := count ts where Todo(Completion.Active)` |
| `allDone(v) = ∀t. t.done` | `ToggleAll := AllDone if all ts are Todo(Completion.Completed) else NotAllDone` |
| `showClearDone(v) = ∃t. t.done` | `ClearCompleted := Shown if any ts are Todo(Completion.Completed) else Hidden` |
| guard `[\|todos\| = 1]` | gap 2 guards, reusing `count`, `all`, `any` |
| `∀t ∈ todos. t.done := true` | Part C: `Todos each Todo(Completion.Completed)` |
| `todos := todos ++ [...]`, `todos - id` | Part C: `+=`, `-=` |

### Where SumSpec differs

In an EFSM, `allDone` could instead be a control state:
`WithTodos_AllDone` and `WithTodos_NotAllDone`. That needs automatic
transitions between them (such as an `allDoneEvent` fired when the last
todo is completed, and its reverse), and the number of states
multiplies. In SumSpec, `ToggleAll` is a sum inside the state, so it is
both data and control. `:=` lets it stay a sum that transitions can
still match on (`toggleAll :: Screen.WithTodos(ToggleAll.AllDone) -> ...`),
while it is never written, like Option 2's function.

A derivation can be read as that pair of automatic, guarded transitions,
fired at once so the in-between state is never visible. A code generator
may implement it either way: as a computed property, or as a reactive
update.

## Rules this implies (open)

- A transition can't write a derived value; `toggleAll` changes the
  todos instead (Part C).
- A derivation's sources must be in scope, and a derivation may not
  depend on itself, directly or through other derivations.
- Each branch is a variant of the factor's type; bare variants resolve by
  that type.
- `count` returns a number: a built-in `Count` atomic, or any atomic.
- The expression language never has an infix `*` outside parentheses,
  so a derivation ends where the next factor starts.
