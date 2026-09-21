# Roadmap

Written 2026-09-20, two days into the project. Dated because a roadmap that
isn't is just a wish list.

The ordering rule throughout: **things that change what the tool can do come
before things that make it nicer**, and anything whose failure mode is
expensive waits until the cheap failures are understood.

---

## Shipped

Desks with groups, vendor badges and a home per runtime. A folder tree you can
rearrange. A reader with tabs that open themselves when an agent writes a file.
A cross-vendor meter reading real quota, with a router that speaks only when
there is something to act on. A mailbox bridge between vendors. Discovery of
agents, Codex profiles and SSH hosts. Settings, first run, an app bundle,
a headless CLI, 33 tests, CI, and self-update from inside the app.

Splits, so a desk can hold the agent and a shell at once. Fan-out, so one
question can be asked of a dozen directories at once and reconciled into one
answer, priced against real quota before it runs.

Six runtimes: claude, codex, gemini, copilot, grok, ollama.

---

## Next

### 1. Use it for a week, then re-read this file

Not a feature, and deliberately first. Two days of building, zero days of
working in it. Every item below is a guess, and a week of real use would
replace the guesses with evidence — probably reordering this list and deleting
some of it.

### 2. ~~Releases, so nobody has to build it~~ — shipped 2026-09-20

An earlier draft of this file said releases needed a $99 Developer ID. That
conflated two unrelated things, and the mistake cost nothing only because
somebody questioned it:

- **A GitHub release is free** on any account. Downloading a zipped `.app` is
  now the install path; cloning and building is for contributors.
- **A Developer ID is $99/year** and buys exactly one thing: *notarisation*,
  which removes the "unidentified developer" warning. It is not required to
  publish, and the README says plainly what the warning is and how to get past
  it.

Notarisation stays unbought until somebody who is not the author is actually
blocked by that warning. Worth recording for anyone who reaches for the
obvious workaround: **Apple's fee waiver does not apply here.** It requires a
legal entity — explicitly not an individual or sole proprietor — that is a
nonprofit, accredited educational institution or government entity. Being a
student, or a service member, qualifies the institution, not you. And signing a
personal MIT project under an employer's, a university's or a government
entity's Developer ID tells everyone who downloads it that *that organisation*
published it, and makes them answerable for what it does. If notarisation ever
matters, it is $99 in your own name.

### 3. ~~Splits — more than one terminal per desk~~ — shipped 2026-09-20

`cmd-d` splits right, `cmd-shift-d` splits down, `cmd-w` closes a pane and
`cmd-[` / `cmd-]` move between them. Pane 0 is the agent; the rest are login
shells in the same directory.

One axis per desk rather than a nested tree, and four panes maximum. Nested
splits are the obvious next ask and are deliberately not built: nesting doubles
the interaction surface to serve a layout nobody has requested. **If you want
them, that is [an issue](../../issues) with a thumbs-up on it.**

### 4. A remote session, localhost-only

Reaching a desk from a phone. Designed and deliberately not built.

A web terminal is remote shell execution on the host machine, which makes it
the first feature here whose failure mode is expensive rather than annoying.
Everything else can be wrong and cost an afternoon.

So the shape is fixed in advance: **bind to 127.0.0.1, hardcoded**, and reach
it over Tailscale or an SSH tunnel. That moves identity to something already
audited instead of to auth code written here. A public listener is out of
scope, not deferred.

Worth noting that Claude Code already has `--remote-control`, so for one vendor
this exists. What is missing is the cross-vendor version and the desk model.

### 5. Better highlighting

The reader's highlighter is regex over comments, strings, keywords and numbers.
It is honest about being shallow and returns plain text rather than guessing on
formats it does not know. tree-sitter would make it correct.

Low priority: the current version is good enough to read a diff, which is the
whole job.

---

## Later, and less certain

### Cross-platform

macOS-only is an adoption ceiling for an open-source project, and the author was
wrong to treat it as acceptable.

A spike settled the feasibility ([spikes/cross-platform/RESULT.md](spikes/cross-platform/RESULT.md)):
`iced` + `iced_term` + `wgpu` builds and launches with Command Line Tools alone.
`gpui` does not — its build script needs the Metal compiler, which ships only
with Xcode.

Two things block it. `iced_term` is one maintainer against SwiftTerm's
commercial use, and **PDFKit has no Rust equivalent** — opening a PDF inline is
one of the few things Project Coldfall does that Zed still cannot.

The preparation is already done: `ColdfallCore` is Foundation-only and CI
enforces that, so a front end in another language is a UI project rather than a
rewrite. [docs/FORMATS.md](docs/FORMATS.md) is the contract.

### A router that acts

The meter knows each vendor's remaining quota. It currently advises: *claude
84% used, codex only 19% — send the next one to codex.* It could route.

Not built because advising is obviously right and routing is obviously
arguable. Handing your work to a different vendor because a number crossed a
threshold is a decision, not an optimisation.

### Orchestration past the mailbox — partly shipped 2026-09-20

The bridge did one question and one answer. Three things it could not express:
**fan-out**, **multi-turn between agents**, and **handoff state**.

**Fan-out is built.** The same question across N directories in parallel, then
a merge pass with every answer as context. A run is a directory of ordinary
threads, so you can still `cat` the state of one — which is the constraint that
keeps this from becoming a framework.

The other two are deliberately not built, and the reasons differ:

- **Multi-turn (A → B → A → B).** The stopping rule is the whole problem. A
  convergence check between two agents is unreliable, and unreliable plus a
  loop is how you spend a week's quota on an argument. If this is ever built it
  gets a hard round cap and a human reading the result, not a "run until they
  agree" button.
- **Structured handoff state.** This is where a schema gets invented and the
  project becomes a worse programming language. LangChain, AutoGPT and crewAI
  all started at "agents hand work to each other" and ended as DAG config
  formats nobody can debug. The thread stays prose.

The line to hold, for anyone extending this: **if you cannot `cat` the state of
a run, it is the wrong design.** The mailbox's entire virtue is that it is a
file — readable, diffable, keepable. A fan-out is a directory of those. A graph
in a config file is not.

---

## Not building, and why

The reasons matter more than the list. Each of these was considered and
rejected on grounds that should survive someone disagreeing with them.

**An agent editor.** Those files belong to the vendor. Claude Code owns
`.claude/agents` and its schema, and a field added upstream next month would be
silently dropped on save — losing configuration people tune over months.
Project Coldfall reads them and routes you to the vendor's own tooling to change them.

**Agent creation as a form.** Creating an agent well is a conversation. The
vendor's flow interviews you and writes the system prompt, which is the entire
craft. A form here would offer a name, a description and a model dropdown, and
leave the part that matters blank.

**Agent deletion.** A definition and an agent's memory directory are separate
things, and "delete this agent" does not say which. Months of accumulated state
sits in the half that is easy to destroy by accident.

**A dedicated mobile app.** Months of work, an App Store review cycle, and a
second UI to maintain, to reach a use case an SSH session already serves.

**A public-facing server.** See above. Localhost plus a tunnel, or nothing.

**Forking VS Code.** Its terminal is xterm.js, which is the specific thing that
drove this project into existence — a fork would begin already holding the
problem it exists to solve. It would also mean inheriting 1.5 million lines to
keep a file tree, since an editor's real value is the LSP and completions this
tool deliberately does not want. Project Coldfall is about 2,300 lines.

**An editor.** Agents write, you read. That single decision is why the reader is
a hundred lines and why a PDF opens at all.

---

## What would change this plan

- **Somebody else uses it.** Every priority above is one person's guess.
- **`iced_term` matures, or is replaced.** That unblocks cross-platform.
- **A vendor exposes quota locally for Gemini or Copilot.** The extension point
  is already there: drop `~/.local/share/coldfall/limits/<vendor>.json` and it
  appears, no code change.
- **ACP gets a session model that does not bundle its own CLI.** The reason the
  agent panel in ACP-based editors cannot run your desks
  ([DESIGN.md §2](DESIGN.md)) is structural today. If that changes, some of this
  becomes unnecessary.
