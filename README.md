# README.md

SumSpec is a language defined in our application specification with types and transitions. It uses type-theory (sum-type and product-type) and state machine to describe the system (application).

## Specification

Check out `./spec/spec-v1.md` (language version 1.0). Ideas for later versions are in `./spec/proposals.md`.

See `VERSIONING.md` for how the language and the tool are versioned, and `CHANGES.md` for what changed in each release.

Example specs, in `example/`:

- `example/drone`: a drone mission planner app.
- `example/todomvc`: the user interface of [TodoMVC](https://todomvc.com).
- `example/git`: the core of a local [Git](https://git-scm.com) repository.

## Development environment

```
nix develop
```

## Using the `sumspec` CLI

Inside `nix develop`, build and run the CLI with cabal:

```
cabal run sumspec -- check example/drone
```

To install `sumspec` instead, into cabal's `installdir` (`~/.local/bin` by
default; make sure it's on your `PATH`):

```
cabal install exe:sumspec
```

### `sumspec check FILE`

Parses the spec and type-checks it. A valid spec prints nothing and exits
with code 0. Otherwise every error is printed to stderr, sorted by
position, and the exit code is 1:

```
$ sumspec check test/check/error-bad-path.sumspec
test/check/error-bad-path.sumspec:10:20:
   |
10 | notVariant :: Page.Nope -> Page.Home
   |                    ^
Nope is not a variant of Page
...
```

### `sumspec parse FILE`

Parses the spec without type-checking it, and prints it back in a
canonical layout: one definition per line, with comments removed. A
parse error is printed to stderr with exit code 1.

```
$ sumspec parse test/parse/v1-entry-point.sumspec
...
App = Z
Z = Y * C
Y = V1 | V2 | V3 A
trans1 :: Y.V1 -> Y.V3(A)
trans2 :: Z(Y.V1 * C) -> Z(Y.V2 * C)
```

## Running the tests

```
cabal test
```
