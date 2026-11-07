# SumSpec

**A type-safe spec language for spec-driven development :
humans and AI agents edit it and approve each other's
changes, and agents generate the application from it.**

SumSpec is a small language for an application's specification. You
describe specification in [algebraic data type](https://en.wikipedia.org/wiki/Algebraic_data_type)(like in [Type theory](https://en.wikipedia.org/wiki/Type_theory)) and
transitions (like in [finite-state machine](https://en.wikipedia.org/wiki/Finite-state_machine)).

## The idea

In AI agents era, spec-driven development has become popular more and more:
write the specification first, have a human approve it, and let an agent
generate the code from it. But the spec is usually prose: Markdown
documents that are long, ambiguous, and hard to keep consistent as they
grow. Nothing tells you that two sections contradict each other, that a
state has no way out, or that a rename missed a paragraph.

SumSpec keeps the workflow and changes the spec. The specification is
written in a type-safe language instead of human language:

**For example we describe the git: Git's file life cycle:**

```haskell
Repository
  = Uninitialized
  | Initialized (Head * Branches * Files * Operation)

Files = [FileState by Path]

FileState
  = Untracked
  | Unmodified
  | Modified
  | Staged
  | StagedAndModified
  | Conflicted

add Path#p
  :: Files[p]
  => FileState.{Untracked | Modified | StagedAndModified} -> FileState.Staged
```

Checkout `./example/git.sumspec` for the full git specification example.

**We can describe UI**, for example I gave this to Opus 4.5 and it generates the below design in [Penpot](https://penpot.app/?utm_red=g&utm_group=&gad_source=1&gad_campaignid=23620085724) (open-source Figma alternative) for me:

```haskell
App = Map * Plots * NewPlot

NewPlot
  = Closed
  | Open PlotController

PlotController  @control segmented
                @region panel
                @placement right
  = Points
  | Route RouteSettings

RouteSettings           @view form
  = RouteSpacing        @control stepper
  * FieldMargin         @control stepper
  * CoverageArea        @control segmented
  * StartPoint          @control point_picker
  * ObstacleBoundary    @control stepper
  * SingleSideSpraying  @control toggle

RouteSpacing        = Meter
FieldMargin         = Meter
StartPoint          = Point
ObstacleBoundary    = Meter
SingleSideSpraying  = Bool

CoverageArea
  = RouteOnly
  | RouteAndBoundray
  | Boundary

savePlot :: App => NewPlot.Open -> Plots' * NewPlot.Closed
    @control button

cancelPlot :: App => NewPlot.Open -> NewPlot.Closed
    @control button
```

[Image]()


## Workflow

- **Types at the core, prose where it helps.** The states and
  transitions are types; the intent behind them, the reasons and the
  edge cases go in comments next to the definitions they explain. The
  checker holds the core, and the comments never have to carry it.
- **Humans and AI agents work on it together.** A spec is short, and it
  reads as a list of states and of what each event does, without the
  noise of an implementation. It's a round trip: a human writes or
  changes the spec and the agent reviews it, or the agent proposes a
  change and the human approves it, and around again. Every change, from
  either side, passes the checker before anyone reviews it.
- **AI agents generate from it.** An agent builds the application from
  the exact states and transitions the spec lists, instead of guessing
  from prose.
- **The type system maintains it.** The state is a type, so a state that
  isn't in the type can't happen ("loading and failed at the same time"
  can't be written). Every change is a transition from one state to
  another. The checker reports unknown names, impossible patterns,
  states nothing ever reaches, transitions that can never happen, and
  two transitions of one event that compete for the same state, before
  any code exists.
- **Language tools support it.** Like any programming language, a spec
  gets tooling: the `sumspec` checker today, and a language server
  (errors as you type, go-to-definition, syntax highlighting) next.

In short: spec-driven development, where the spec is easier to maintain
because a type system and real language tools look after it.

Tip: For frontend development it is the best practice to follow TEA (The Elm Architecture) as far as this language is close to it.

## More examples

A network link that connects, fails and retries:

```haskell
__atomics {
  Session
  Reason = __text
}

__events {
  connect
  connected
  failed
  retry
  disconnect
}

__init :: Link.Offline

-- The app is useful offline too, so it never connects on its own:
-- the user asks for it, and after a failure the user decides to retry.
Link
  = Offline
  | Connecting
  | Online Session
  | Failed Reason

connect              :: Link.Offline    -> Link.Connecting
connected Session#s  :: Link.Connecting -> Link.Online(s)
failed Reason#r      :: Link.Connecting -> Link.Failed(r)
retry                :: Link.Failed     -> Link.Connecting
disconnect           :: Link.Online     -> Link.Offline
```

`Link` is a sum: the link is in exactly one of four states, and only
`Online` has a `Session`, so no code can read a session while
connecting. Each line at the bottom is an event and its transition:
`retry` exists only from `Failed`. `Session#s` names the value the
`connected` event brings, and `Link.Online(s)` stores it. The comment
(`--`) carries what the types can't: why the link behaves this way.

**TodoMVC.** A product (`*`) holds everything on the screen at once. A
guard (`//`) adds a condition: an empty title is not added. A prime
(`Todos'`) marks a part that gets a new value:

```haskell
App
  = Screen
  * NewTodo
  * Filter

NewTodo
  = Blank
  | Typing Text

Screen
  = NoTodos
  | WithTodos (Todos * ToggleAll * Footer)

addTodo
  :: App
  => Screen.NoTodos * NewTodo.Typing(#text)
  // text != ""
  -> Screen.WithTodos(ToggleAll.NotAllDone) * NewTodo.Blank

  => Screen.WithTodos * NewTodo.Typing(#text)
  // text != ""
  -> Screen.WithTodos(Todos' * ToggleAll.NotAllDone * Footer(ItemsLeft')) * NewTodo.Blank

toggleTodo TodoId#id
  :: Todos[id]
  => Completion.Active -> Completion.Completed
  => Completion.Completed -> Completion.Active
```

The full specs are in `example/`:

- `example/drone.sumspec`: a drone mission planner app.
- `example/todomvc.sumspec`: the user interface of [TodoMVC](https://todomvc.com).
- `example/git.sumspec`: the core of a local [Git](https://git-scm.com) repository.

## Where it's useful

- **Spec-driven development with AI agents.** Humans and agents both
  edit the spec and approve each other's changes; the agent generates
  the code from it, and it stays the reference after the code exists:
  change the spec, check it, approve it, and regenerate.
- **User interfaces.** Screens, modes, forms, loading and error states:
  every combination the UI can show is in the type, and every user
  action is a transition.
- **Application cores and protocols.** A repository, an order, a
  connection, a device: anything with a life cycle and rules about what
  may happen when.
- **Design reviews.** A spec is something a team can read and argue
  about before writing code, and the checker answers questions like
  "can this state ever be reached?".

## Influences

- [**Haskell**](https://en.wikipedia.org/wiki/Haskell) and the ML family: for syntax.
- [**TEA (The Elm Architecture):**](https://guide.elm-lang.org/architecture/) for describing the state and event
- [**Type theory:**](https://en.wikipedia.org/wiki/Type_theory) for states
- [**Extended finite state machines (EFSM):**](https://en.wikipedia.org/wiki/Extended_finite-state_machine) for transitions.

## The language

- `spec/spec-v1.md`: the language definition (version 1.0, in
  development).
- `spec/grammar.ebnf`: the grammar.
- `spec/proposals.md`: ideas for later versions.

## The `sumspec` tool

`sumspec check FILE` parses and type-checks a spec. It prints nothing
for a valid spec, or every error and warning with its position.
`sumspec parse FILE` prints a spec back in canonical form.

To build it, run the tests, or contribute, see
[DEVELOPMENT.md](DEVELOPMENT.md).

## Vibe Coded vs Human Revised

The files that fully vibe coded (no human revised) vs human revised files:

| File                      | Human Revised
|---------------------------|--------------
| `./README.md`             | Yes+
| `./spec/spec-v1.md`       | Yes+
| `./example/*`             | Yes+
| `./flake.nix`             | Yes+
| `./DEVELOPMENT.md`        | Yes
| `./src/SumSpec/Syntax.hs` | Yes
| `./test/check/*`          | Yes
| `./TODO.md`               | Yes
| `./spec/proposals.md`     | Partial
| `./spec/grammar.ebnf`     | Partial
| `./test/parse/*`          | Partial

Every thing else is vibe coded without human revised today.
