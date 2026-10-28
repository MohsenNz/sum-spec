# Versioning

SumSpec has two version numbers that change for different reasons.

| | Example | Changes when | Recorded in |
|---|---|---|---|
| **Language version** | `1.0`, `1.1`, `2.0` | The language changes | `spec/spec-v<major>.md`, `CHANGES.md` |
| **Tool version** | `0.1.0.0` | Every release of `sumspec` | `sumspec.cabal`, `CHANGES.md` |

The language version belongs to the language, not to the `sumspec`
tool: agents and other tools read SumSpec too, and they need to know
which features a spec may use without looking at this implementation.

## Language version

The language version is `major.minor`:

- **Major** goes up for a **breaking change**: one after which an
  existing valid spec is invalid, or valid but with a different meaning.
  The minor version starts again at `0` (`1.3` → `2.0`).
- **Minor** goes up for an **additive change**: every spec that was
  valid before stays valid and keeps its meaning. Examples: a new
  optional syntax, or something that used to be an error and now has a
  meaning.

There is no patch number. Corrections and clarifications to a spec
document don't change the language, so they don't change its version.

A spec written for `1.1` is valid in `1.2` and every later `1.x`, with
the same meaning. It isn't necessarily valid in `1.0` or in `2.0`.

### One document per major version

- `spec/spec-v1.md` is the complete definition of every `1.x` version.
  It's a living document: each minor version adds to it.
- When `2.0` starts, `spec/spec-v2.md` is written as a complete
  document, not a diff. `spec-v1.md` is then frozen; only corrections
  go into it.
- `spec/grammar.ebnf` describes the current language version.
- `spec/proposals.md` holds ideas that are in no version yet. Each
  proposal says whether it's additive (next minor version) or breaking
  (next major version).

### "Added in" notes

Everything in a major version's first release (`1.0`, `2.0`) needs no
note. Every feature added in a later minor version gets a line under
its section heading in `spec-v<major>.md`:

```
## Transition inputs

Added in 1.1.
```

So a reader of the document, human or agent, can tell which features a
given language version has.

## Tool version

`sumspec.cabal` follows the Haskell [Package Versioning
Policy](https://pvp.haskell.org): `A.B.C.D`, where `A.B` is the major
version.

- **Major** (`A.B`): a breaking change to the library API or the CLI,
  or support for a new major language version.
- **Minor** (`C`): new features, including support for a new minor
  language version.
- **Patch** (`D`): bug fixes only.

A tool release doesn't have to change the language version: a release
that only fixes bugs or improves error messages implements the same
language version as the one before it.

The version in `sumspec.cabal` changes at release time, not with every
change.

## CHANGES.md

`CHANGES.md` lists every tool release, newest first, with the language
version it implements. Work that isn't released yet goes under
**Unreleased**. Each entry says whether it affects the language or the
tool.

## Releasing

1. Decide the language version of the release: unchanged if no entry
   under **Unreleased** is a language change, the next minor version if
   all the language changes are additive, or the next major version.
2. Move the **Unreleased** entries in `CHANGES.md` under the new tool
   version, with the date and the language version.
3. Set `version:` in `sumspec.cabal` to the new tool version.
4. Add the "Added in" notes for the release's language features, and
   update the version stated at the top of `spec-v<major>.md`.
5. Commit, and tag the commit `v<tool version>` (e.g. `v0.1.0.0`).

Tags are for tool releases only; `CHANGES.md` says which language
version each release implements.

## Starting a new major language version

1. Collect the breaking changes and release them together, not one at a
   time.
2. Copy `spec/spec-v<N>.md` to `spec/spec-v<N+1>.md`, apply the changes,
   and remove the "Added in" notes (everything in `<N+1>.0` is part of
   it from the start).
3. Update `spec/grammar.ebnf`, the checker and the tests.
4. Update the examples in `example/` to the new version. Older versions
   of them stay in the git history.
5. Bump the major tool version.
