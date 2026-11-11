# Promoting SumSpec: plan

How to get SumSpec in front of the people who would use it. Nothing here
is done yet.

The approach: get it ready to try, then launch once and properly, in
several places on the same day.

## Before promoting: make it easy to try

People give a new language about 30 seconds. These matter more than
where it is posted.

1. **A killer demo.** A 2–3 minute video or GIF of the round trip:
   - write a spec;
   - an AI generates the app (TodoMVC in React or Elm);
   - change the spec, approve the diff, and regenerate.

   This shows "type-safe spec-driven development" better than any text,
   and it's what people will share.
2. **Easy install.** Release 0.1.0.0 (see "Versioning" in `TODO.md`) and
   publish it to Hackage. Attach prebuilt binaries for Linux and macOS
   to GitHub Releases. Most of the audience won't have GHC or Nix.
3. **Editor support.** Even the fallback highlighting plus diagnostics
   from `sumspec lsp` makes the language feel real (see `docs/lsp.md`).
   VS Code users judge a language by its extension.
4. **An agent integration.** A Claude Code skill or plugin, or an MCP
   server, that runs `sumspec check` and teaches the agent the language.
   It puts SumSpec where its users already are, so it's promotion in
   itself.
5. **A playground (optional).** The checker compiled to the web with
   GHC's WASM or JS backend, so a link lets anyone try it in the
   browser.

## Where to post

### Launch day (Tuesday to Thursday, morning US time)

- **Hacker News**: "Show HN: SumSpec – type-safe specs for AI-built
  apps". Spec-driven development, AI and Haskell all do well there.
  Stay in the thread and answer every comment.
- **Lobste.rs** (needs an invite): the PL and formal-methods angle.
- **Reddit:**
  - r/ProgrammingLanguages, for design feedback. They welcome work in
    progress, so this can also be done early.
  - r/haskell.
  - The AI angle: r/ClaudeAI, r/ChatGPTCoding and r/cursor.

### The week after

- **Haskell:** Haskell Discourse (discourse.haskell.org), the Haskell
  Weekly newsletter (submit a link), and the Haskell community on
  Bluesky and Mastodon.
- **Formal methods:** the TLA+ Google group and the Quint community.
  Present SumSpec as a complement, a design layer that can export to
  Quint, not as a rival.
- **Spec-driven development:** discussions around GitHub Spec Kit and
  Kiro, and newsletters and blogs about agent workflows.
- **Awesome lists:** awesome-haskell, and AI-coding or spec-driven
  development lists.

## Content

One blog post per audience, each linked from the README:

1. **"Spec-driven development, but the spec type-checks"**: the pitch,
   with a Markdown spec and the same spec in SumSpec side by side.
2. **"Designing apps with sum types"**: for the Haskell and FP audience.
   How SumSpec builds on "make illegal states unrepresentable".
3. **"SumSpec vs Quint and TLA+"**: write `example/drone.sumspec` in
   Quint by hand and compare length, readability, and how easily
   someone who isn't an engineer can read each one. It also shows where
   SumSpec stops: it does no model checking or proofs, and exports to
   Quint for that. The material is in `docs/sumspec-vs-quint-tla.md`.
4. **"Building an LSP in Haskell for a new language"**: a technical post
   that also reaches tooling people.

## Talks (later)

- First, local meetups (Haskell, FP, AI engineering).
- Then ZuriHac, Haskell eXchange, Lambda Days, FOSDEM devrooms, or
  Papers We Love-style events.
- Conferences on AI-assisted engineering: "type-safe specs for agents"
  is a fresh topic there.

## Habits

- **Launch once, properly.** A Show HN that leads to a confusing README
  is hard to repeat. The demo, the install and the README come first.
- **Write down every confusion.** The questions in the first threads are
  the real documentation and roadmap. Turn them into README changes and
  `TODO.md` items.

## Order

1. Release 0.1.0.0, with binaries.
2. The agent integration, and the demo video.
3. The first blog post.
4. Show HN and Reddit, on the same day.
5. Community posts, the week after.
6. The other blog posts, then talks.

## Checklist

- [ ] Release 0.1.0.0 on Hackage, with binaries on GitHub Releases.
- [ ] Fallback highlighting and `sumspec lsp` diagnostics.
- [ ] Agent integration (a Claude Code skill or plugin, or an MCP server).
- [ ] Demo video: spec, generated app, spec change, regenerated app.
- [ ] Blog post 1: spec-driven development with a type-checked spec.
- [ ] Show HN, Lobste.rs, Reddit.
- [ ] Haskell Discourse, Haskell Weekly, formal-methods and spec-driven
      development communities, awesome lists.
- [ ] Blog posts 2–4.
- [ ] A meetup talk.
- [ ] {Optional} A browser playground.
