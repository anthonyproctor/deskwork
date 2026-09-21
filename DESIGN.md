# Project Coldfall — design

A terminal-first console for people who run several long-lived AI agents across
several vendors, and who need to see what that is costing them while it happens.

Working name. Status: design, nothing built.

---

## 1. The thesis

Every coding tool on the market picks one of two units of work.

**The file is the unit.** VS Code, and everything descended from it. The editor is
the centre, the AI is a panel bolted to the side.

**The thread is the unit.** Zed's agent panel, Copilot, Cursor's chat. A
conversation starts, does a job, and is thrown away.

There is a third arrangement that nothing supports, and it is the one that shows
up once you actually live in this stuff for a few months:

**The agent is the unit.**

You stop having conversations and start keeping specialists. Each one has its own
system prompt, its own memory on disk, its own pinned model, its own hooks and its
own tools. A session against one of them is disposable; the specialist is not. It
has been accumulating judgment for months. You do not re-explain your situation,
because it already knows.

Call one of those a **desk**. You open a desk, work, close the window. The desk
persists.

Once the agent is the unit, most of an IDE is beside the point and a few things
nobody builds become essential.

## 2. Why existing tools can't host this

This was tested, not assumed.

Zed is the closest thing available: native file tree, GPU-accelerated terminal
built on `alacritty_terminal`, and first-class support for external agents through
the Agent Client Protocol. On paper it is the answer.

It cannot run desks, and the reason is structural rather than a missing feature.
The Claude Code ACP adapter depends on `@anthropic-ai/claude-agent-sdk` and runs a
Claude Code **bundled inside that SDK** — not the CLI on your machine. Different
binary, different version, different config discovery. Your agent definitions, your
model pins, your hooks and your memory files are all invisible to it.

That is not a bug in Zed. ACP is designed so an editor can host *any* agent, which
means the editor owns the session and the agent is interchangeable. Desks invert
that: the desk owns the continuity and the window is interchangeable. The protocol
is fine. The ontology is the wrong way round.

Two further gaps, smaller but real:

- **No collaboration between agents.** ACP threads are isolated. Two agents on one
  problem is two conversations that cannot see each other. No handoff, no shared
  context, no side-by-side comparison.
- **No cost surface.** Every client shows you a session cost at best. None shows
  consumption across agents, across days, against a weekly limit.

## 3. Non-goals

These keep the project finishable.

**Not an editor.** Agents write the code. A human running this reads diffs, skims
files, and checks work. That means a **reader**: syntax highlighting, diffs, search,
and an image and PDF viewer. It does not mean LSP, completions, multi-cursor,
refactoring or a debugger. Dropping those removes most of the cost of building an
IDE, and it is what makes a PDF viewer trivial to include — something Zed still
does not have after years of requests.

**Not a terminal emulator.** SwiftTerm handles that today, libghostty later.

**Not an agent runtime.** Agents are subprocesses. We drive them, we do not
reimplement them.

**Not a new protocol.** Speak ACP where ACP fits. Extend it where it does not, and
upstream the extension rather than forking the idea.

## 4. Shape

```
┌─────────────┬──────────────────────────────┬───────────────┐
│  DESKS      │  work area                   │  reader       │
│             │                              │               │
│ ● money     │  terminal ── the desk's own  │  diff / file  │
│ ○ market    │  CLI, unmodified, in a real  │  / PDF /      │
│ ● career    │  pty            │  image        │
│ ○ health    │                              │               │
│             │                              │               │
│  FILES      │                              │               │
│  tree       │                              │               │
├─────────────┴──────────────────────────────┴───────────────┤
│  money · Opus 5 · wk ████████░░ 79% 1d1h EASE OFF · ctx 41% │
└────────────────────────────────────────────────────────────┘
```

Four regions. The left rail lists desks and the file tree. The centre hosts
terminals, one per desk, tabbed or split. The right is the reader. The bottom is
the meter, always visible.

The important detail: **the centre is a real terminal running the real CLI.** Not a
reimplementation, not an SDK embedding. Whatever the vendor ships is what runs, so
agent definitions, hooks, memory and model pins all work because nothing is
intercepting them. Everything else in the app is instrumentation around that.

## 5. The desk model

A desk is a config record plus whatever state its agent keeps on disk.

```toml
[desk.money]
agent    = "finance-copilot"      # the vendor's own agent/profile name
runtime  = "claude"               # claude | codex | gemini | copilot | custom
model    = "opus"                 # advisory; the runtime enforces
cwd      = "~/work/ledger"
tags     = ["money", "slow-lane"]

[desk.market]
agent    = "market-copilot"
runtime  = "claude"
model    = "fable"
cwd      = "~/work/ledger"
```

Operations: **open**, **resume**, **fork** (branch a desk's context into a scratch
copy), **retire**. Resume and fork lean on ACP's session capabilities where the
runtime offers them, and on the CLI's own resume flags where it does not.

A desk is also the unit the meter attributes to, which is the thing that makes
cost legible for the first time.

## 6. The meter

Consumption is invisible today. You find out you are out of budget by being out of
budget, and the only recourse is to open a browser.

Two sources, and the first one is better than expected. Claude Code hands a
statusline command a JSON payload on stdin that already carries the authoritative
numbers:

```
rate_limits.seven_day.used_percentage    # the real weekly limit
rate_limits.seven_day.resets_at
rate_limits.five_hour.used_percentage
context_window.used_percentage
cost.total_cost_usd
prompt_cache.hit_ratio, .misses, .last_miss_cause
```

Second source, for history and per-desk attribution, is the local transcript
store. Two things a naive reader gets wrong:

1. **Deduplicate on `message.id`.** Streamed assistant messages are written to the
   transcript more than once. On a real 30-day window this inflated the total by
   roughly 2x — 22,304 duplicate ids out of 44,636 records.
2. **Cache writes are not free.** Weight input ×1, cache write ×1.25, cache read
   ×0.1, output at the model's own rate. Otherwise "keep sessions short" looks like
   a saving when it is often the opposite, because every new session rebuilds the
   cache at 12.5× the cost of reading it.

The meter is a bar, a projection, and a verdict. It shouts when the week is nearly
spent, because that is the only moment the information changes behaviour.

## 7. The bridge, and the router

This is the part that does not exist anywhere, and it only becomes possible once
one window holds several vendors.

### The bridge is a mailbox, not a protocol

The obvious design is a wire protocol. It is the wrong one. Two agents from
different companies hand work back and forth through an **append-only markdown
thread**, and that beats a protocol on four counts:

- **Vendor-agnostic.** Anything with a headless mode can join. No adapter, no
  SDK, no coupling to anybody's release train. Compare ACP, where the Claude
  adapter runs a Claude Code bundled inside the Agent SDK rather than the CLI on
  your machine (section 2).
- **The thread IS the context.** Every headless invocation starts with no memory,
  so the file carries the conversation. This is why it must APPEND. Replacing the
  thread once destroyed a long exchange by overwriting it with an answer from a
  session that had never read it.
- **Inspectable.** The whole exchange is a file you can read, diff and keep.
- **The responder cannot write**, enforced by the vendor's own flag rather than
  asked for politely: `claude -p --permission-mode plan`,
  `codex exec --sandbox read-only`. Where a vendor has no such flag, Project Coldfall
  says so in the UI instead of implying a guarantee it cannot make.
- **But read-only is not private, and that is the real risk.** Those flags block
  writes and nothing else. The responder reads everything under its working
  directory. The first live test of this bridge sent Codex grepping through the
  whole workspace, transcripts included, to answer a question about one script.
  The working directory is therefore a privacy boundary: Project Coldfall shows it
  before sending, confirms it once per vendor, and `scope` in bridge.toml
  narrows it. An earlier draft of this document described the responder as
  simply "read-only", which overstated the guarantee.

Credit where it is due: this pattern is not invented here. It comes from a
working hand-rolled setup — a pair of markdown files and a shell script — that
had already learned the append rule the hard way. Project Coldfall generalises it to
arbitrary runtime pairs and ships it built in, so a new user needs nothing but
the CLIs they already have.

Three moves fall out of the same primitive: a **second opinion** (same question,
different vendor), a **handoff** (move a thread across with context intact), and
a **review** (one agent reads another's diff).

### The router

The meter knows each vendor's remaining budget. The desk list knows which runtime
each desk uses. So the console can say the useful thing:

> Claude's weekly window is 84% gone and it is Wednesday. Codex is barely touched.
> Run this one on Codex.

## 8. What is already solved

| Piece | Source |
|---|---|
| Terminal engine | **SwiftTerm** — VT100/xterm emulator in Swift, AppKit front end, CoreText rendering, pty included; ships in CodeEdit and commercial SSH clients |
| Terminal engine, later | **libghostty** once it renders — see the correction below |
| Multi-vendor agents | **ACP** — open JSON-RPC, Zed and JetBrains co-maintain it; Claude, Codex, Gemini, Copilot, Cursor all ship adapters |
| Syntax highlighting | tree-sitter |
| PDF and image | platform native (PDFKit on macOS) |

Ours to write: the desk model, the meter, the router, the cross-agent moves, the
shell that holds them.

### Correction, 2026-09-19

An earlier draft listed libghostty as the terminal engine and called it solved. It
is not, yet. **`libghostty-vt` is parsing and terminal state only** — it tells an
embedder what to draw, not how. Mitchell Hashimoto's own write-up puts GPU
rendering and input handling in the "longer term" bucket, and `ghostling`, the
reference embedder, writes its own renderer in Raylib.

Embedding libghostty today therefore means writing a Metal renderer, a glyph
atlas and keyboard encoding. That is the largest single piece of work in the
project and it is not the interesting part.

SwiftTerm covers it now. The open risk is throughput: SwiftTerm renders through
CoreText rather than the GPU, and a terminal that cannot keep up is the exact
complaint that started this project. That is the first thing to measure, before
any other code gets written.

Two of the three genuinely hard problems are off the shelf and open source. That is
new as of this year and it is what makes the project tractable.

## 9. Milestones

**M0 — statusline.** A script that renders the meter in an existing terminal. Ships
in a day, useful immediately, proves the data contract the meter pane will consume.
*Done, in a form, before this document existed.*

**M1 — desk switcher.** Launch, list, resume and retire desks from one window. A
terminal grid over SwiftTerm. No reader yet. At this point it replaces the tab
sprawl, which is most of the daily benefit.

**M2 — meter pane.** Live weekly and five-hour windows, per-desk history, cache
diagnostics. Click through for detail.

**M3 — reader.** File tree, diffs, syntax highlighting, PDF. The pane that makes it
an IDE rather than a terminal multiplexer.

**M4 — router.** Multi-vendor budget awareness and the three collaboration moves.

M1 is the honest test. If the desk switcher alone is not worth opening every day,
the rest does not rescue it.

## 10. Open questions

- **Host language — DECIDED: Swift.** Ghostty's own macOS app is Swift, SwiftTerm
  is Swift, PDFKit is free, and ACP is plain JSON-RPC over stdio so no binding
  matters. Rust would buy cross-platform nobody needs and cost the entire GUI
  layer. Revisit only if this ever has to leave macOS.
- ~~**Can SwiftTerm keep up?**~~ **ANSWERED 2026-09-19: yes.** 200k lines in 0.23s
  steady state, against Terminal.app's 0.27s. CoreText is not the bottleneck.
  Measurement and caveats in `spikes/terminal-throughput/RESULT.md`. Still worth
  a second pass with realistic coloured/TUI output before M3.
- **Does a desk need to be one process?** Splitting a desk across panes is
  appealing and may fight the runtime's own session model.
- **How much ACP, how much pty?** Terminal-only is honest and simple but gives the
  app no structured view of what the agent did. ACP gives structure but, as
  section 2 showed, can bypass the user's real CLI. Probably both: pty for the
  desk, ACP for the cross-agent moves.
- **Per-vendor meter parity.** Claude Code exposes rate limits. Whether Codex and
  the others expose anything comparable is unknown and needs checking before the
  router is designed in detail.

---

## Provenance

The desk pattern in this document comes from a working private setup: a dozen
persistent agents, each with its own memory directory, hooks and pinned model,
driven by a shell script that wraps the vendor CLI. Everything here is the
mechanism. None of the content, prompts or memory from that setup appears in this
repository and none ever should.
