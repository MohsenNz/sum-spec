# Literal patterns: open questions

A literal pattern says "the value is this literal": `Count(0)`,
`Name("main")`. It would be usable where a pattern is, and a named
constant is a name for one (see "Literal patterns and named constants"
in `proposals.md`).

Answer each question under its **Answer:** line. The result is written
into `proposals.md` as "Literal patterns and named constants" (question
13, arithmetic in targets, is the separate proposal "Arithmetic in
targets"). This file is the record of the decisions. `Leaning` is only a
starting point.

## 1. Syntax

Is `Count(0)` the only form, or is a bare `0` also a pattern where the
type is known? Are negative literals allowed (`Count(-1)`)? How does the
parser tell `A(1)` from a payload pattern `A(B)`?

Leaning: only `Type(literal)`; a literal after `(` is not a type, so one
token of lookahead decides.

**Answer:** Only `Type(literal)`; a bare `0` is not a pattern. A payload
pattern starts with an uppercase type name, and a literal starts with a
digit, a `-` or a `"`, so the first token after `(` tells them apart,
with no backtracking.

A literal is not allowed directly as the payload of a variant: write
`NewTodo.Typing(Text("hi"))`, not `NewTodo.Typing("hi")`. The payload's
type is always named.

## 2. Which types take a literal

`__int` and `__text`: yes. And `__float` (float equality; an integer
literal for a float; a decimal)? A newtype over a base (`Title("x")`
where `Title = Text`)? An atomic with no base (none)? Reuse the
literal-fit table in "Comparing values" in `spec-v1.md`?

Leaning: the same table as comparisons; `__float` allowed, since the
comparison `==` already allows it.

**Answer:** The same table as comparisons. The head type resolves
through newtypes to a base, and the literal must fit that base:

| The head type resolves to | Literal that fits |
|---|---|
| `__int` | integer |
| `__float` | integer, decimal |
| `__text` | string |
| a sum without payloads | none (use the variant) |
| an atomic with no base | none |
| a product, a list, a sum with payloads | none |

`__float` is allowed, since a literal pattern is the same test as `==`.
`Meters(3)` and `Meters(3.0)` are the same value. Two types with the
same base stay different (`Meters(3)` is not `Seconds(3)`).

## 3. Only equality?

Only "is this value", or also ranges (`Count(0..9)`) and comparisons
inside a pattern? Guards already compare.

Leaning: only equality; ranges stay in guards.

**Answer:** Only equality. Ranges and comparisons stay in guards
(`c >= 0 and c <= 9`).

## 4. Alternation of literals

Is `Count(0 | 1)` in or out? The same for text: `Mode("a" | "b")`.

Leaning: out for now; two transitions or a guard (`c == 0 or c == 1`).

**Answer:** Out. `Count(0 | 1)` is not a pattern; write two transitions or
a guard (`c == 0 or c == 1`). It can be added later without breaking
anything.

## 5. Where a literal pattern may appear

Which of these: a source, a guard, an `__init`, an input head, an
element key (`Lines[3]`)? And in a target? A literal in a target sets a
value, which is the open gap "Values inside a new state"
(`efsm-gaps.md`).

Leaning: source, guard and `__init`; not the target, until that gap is
decided. (Changed: a target is allowed, as a constant; see the answer.)

**Answer:**
- Allowed: a source, a pattern in a guard, an `__init` (so a part can
  start at a given value: `Count(0)`), an input head
  (`setSpeed Speed(0) :: Moving -> Stopped`: the transition applies only
  for that input), and an element key (`Slots[Slot(0)]`: the element
  with that key; only a key type with a base takes a literal).
- Also allowed: a target, as a constant. A literal there sets the value
  (`Footer(ItemsLeft(1))`) and must fit its type. It only narrows "any
  value" to one value, as a variant in a target already does. A part
  left out of a new state stays unspecified.
- An input head with a literal needs the overlap rule of question 7 to
  look at inputs: two transitions of one event whose inputs are
  different literals do not overlap. Before implementing, check what the
  overlap analysis does with inputs today.

## 6. Binding

Can a literal pattern also bind its value (`Count(0)#c`)? The value is
known, so a binding adds nothing.

Leaning: no.

**Answer:** No. `Count(0)#c` is an error, with the message "a literal
pattern has a known value; write the literal, or define a named
constant". A repeated literal is a named constant, and a bare binding
(`Count(#n)`) binds an unknown value, so the two forms stay separate.

## 7. Order of patterns in the checker

A literal is a subset of its bare type (`Count(0)` is inside `Count`)
and disjoint from a different literal of the same type. What do the
overlap warning and the shadowing check do with that? Is `Count(0)`
against `Count(0)` an exact repeat?

**Answer:** A literal behaves like a variant of an unbounded sum of that
type, so the existing rules apply:
- `Count(0)` and `Count(0)` are equal (compared by value, so `Meters(3)`
  and `Meters(3.0)` are equal).
- `Count(0)` and `Count(1)` are disjoint: no overlap warning.
- `Count(0)` is inside `Count`: two transitions of one event, one from
  each, can apply to the same state, so the overlap warning fires as it
  does today for a variant against its sum.
- Literals of different types never relate.
- The same rules apply to input heads: two transitions of one event
  whose inputs are different literals (`Speed(0)`, `Speed(1)`) are
  disjoint, and a literal input against a bare input (`Speed`) overlaps.

## 8. Reachability

The reachability check tracks variants, not values. Is a literal treated
as its bare type (safe, but blind to values), or does it warn when
`__init` has `Count(0)` and a transition starts from `Count(1)`?

Leaning: treated as the bare type for reachability.

**Answer:** Reachability tracks values too, conservatively, as a warning.
- For each type, the checker tracks the values it can hold: a finite set
  of literals, or "any".
- `__init` and a literal in a target add that literal to the set.
- Anything else makes the set "any": an arithmetic expression
  (`Attempts(n + 1)`), a bound input, a prime (`Count'`), and a part left
  out of a new state.
- A literal in a source (`Count(5)`) is reported as unreachable only when
  the type's set is a finite list that does not contain it.
- Guards are ignored (safe: more states look reachable, never fewer).
- Tracking is per type, not per place in the state, and no relation
  between parts is kept. It over-approximates and never warns wrongly.
- It is a later step. The first version of literal patterns treats a
  literal as its bare type for reachability (a transition from `Count(1)`
  is not reported unreachable when `__init` has `Count(0)`).
- It says nothing where values are computed or left out (`n + 1`, a
  footer count left out in todomvc). It fires where the spec writes its
  values explicitly, and it brings back the open point in gap 7 of
  `efsm-gaps.md`: a warning for a left-out part nothing ever sets.

## 9. Redundancy with a guard

`Count(0)` in a source and `c == 0` in a guard say the same. Is a lint
worth it, or are both fine?

Leaning: both fine, no lint.

**Answer:** Both fine, no lint. A literal pattern is for a value that
identifies the state; a guard is for conditions and for comparisons
between values.

## 10. Named constants

May a named constant be a pattern head (`Zero` for `Count(0)`)? A
constant of a sum variant is already a pattern. What does a constant of
a constant mean here (`Low = Zero`)?

**Answer:**
- Yes. A constant defined as `Zero = Count(0)` is a pattern equal to
  `Count(0)`; one defined as `Fix = GPSFix.Fix3D` is a pattern equal to
  `GPSFix.Fix3D`. It takes no arguments, and the rules for where a
  literal pattern may appear (question 5) apply to it.
- Constants of constants stay out.
- The proposal is one text with two steps: constants as comparison sides
  first, then literal patterns everywhere, including a constant in
  pattern position.

## 11. Printing and round trip

The canonical form of a text literal (no escapes today) and of a decimal
(as written, or normalized).

Leaning: as written.

**Answer:** As written. The printer keeps the literal's spelling
(`Count(0)`, `Count(-1)`, `Meters(1.5)`, `Name("main")`). Text has no
escapes, as in guards. Equality in the checker is by value, so `3` and
`3.0` are equal even though they print differently.

## 12. Version impact and generators

Confirm the impact is additive (`A(1)` is a syntax error today). What
must a code generator test for each type (strict equality for text,
exact equality for integers, and for floats)?

**Answer:** Additive: `A(1)` is a syntax error today, so no existing
spec changes meaning. A generator tests exact equality for every type:
integers, strings character by character with no normalization, and
floats as the target's own float equality (the spec makes no promise
about rounding, which is another reason to prefer integers for values
that identify a state).

## 13. Arithmetic in targets

Should a target compute a value from the values the transition binds,
as in `Count(c + 1)`? Derived values (Part B of "How updates change
values") would make type definitions verbose; an expression puts the
change where it happens.

Leaning: yes, kept small.

**Answer:** Yes, small. The full proposal is "Arithmetic in targets" in
`proposals.md`. In short:
- `Head(expr)` in a target, where `expr` has the type `Head` wraps
  (`Attempts(n + 1)` with `Attempts(Int#n)` in the source), or a
  parenthesized expression where its type is expected
  (`Attempts#attm` in the source, `(attm + 1)` in the target).
- Built from bound names, literals and named constants with `+`, `-`,
  `*` and parentheses; operands of one type; `__int`, `__float` and
  their newtypes only. No division, calls or text operations.
- One expression language for targets and guards.
- Cost: the checker cannot verify an invariant such as "ItemsLeft is the
  number of active todos".
