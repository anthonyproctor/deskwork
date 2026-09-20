# Deskwork

**A terminal-first console for running several long-lived AI agents, across several vendors, without losing track of what it costs.**

macOS · Swift · early, but it runs

---

## The idea

Every coding tool picks one of two units of work. VS Code and its descendants treat the **file** as the unit. Zed's agent panel, Copilot and Cursor treat the **thread** as the unit — a conversation starts, does a job, gets thrown away.

Once you have been living in this stuff for a few months, neither fits. You stop having conversations and start keeping **specialists**: one for your infrastructure, one for a particular client, one for your notes. Each has its own system prompt, its own memory on disk, its own pinned model. The session is disposable. The specialist is not — it has been accumulating judgement for months, and you don't re-explain your situation to it.

Deskwork calls one of those a **desk**, and makes the desk the unit.

## What it does

**Desks, not threads.** Each desk owns a long-lived terminal running the vendor's own CLI. Switching desks swaps which terminal is visible; the rest keep running. Come back an hour later and it is mid-thought where you left it.

**It never reimplements an agent.** Deskwork launches `claude`, `codex`, `gemini` or `copilot` in a real pty. Your agent definitions, hooks, memory files and model pins all apply, because nothing is intercepting them. This is the point: ACP-based editors run a Claude Code bundled inside the Agent SDK rather than the CLI on your machine, which is why your own agents do not exist there.

**A folder tree and a reader.** Agents write, you read. The reader opens PDFs, images and text. Being read-only is what keeps it about a hundred lines instead of an editor — and why opening a PDF is trivial here.

**A meter that spans vendors.** The strip along the bottom shows where the week is going and says so when one vendor is carrying all of it. Consumption comes from files the CLIs already write — Claude's transcripts, Codex's `token_usage_record` files. Remaining quota is harder: no CLI writes it to disk, and only Claude Code knows it, which it tells its statusline and nobody else. So Deskwork offers to *be* that statusline — a recorder that captures the numbers and then hands stdin to whatever statusline you already had, printing its output unchanged. Turn it on in Settings.

**A cross-vendor bridge.** Put a question to an agent from a different company and get an answer back with the whole conversation as context. It is a mailbox, not a protocol — see below.

## Requirements

- macOS 13 or later
- A Swift toolchain. **Xcode is not required**; Command Line Tools is enough:
  ```sh
  xcode-select --install
  ```
- At least one agent CLI, though the app opens fine without any: Claude Code, Codex, Gemini CLI, or GitHub Copilot CLI

## Install

```sh
git clone https://github.com/anthonyproctor/deskwork
cd deskwork/app
swift build -c release
.build/release/Deskwork
```

First launch writes a working config from whichever CLIs it finds and shows a welcome screen explaining what it found. There is nothing to set up by hand.

## Configure

Settings (`cmd-,`) covers everything. If you would rather edit the file, it lives at `~/.config/deskwork/desks.toml` and remains the source of truth:

```toml
[desk.shell]
# A plain shell first, so opening the app costs nothing.
command = "exec zsh -l"
cwd = "~"

[desk.api]
group   = "work"          # desks are not a flat list
agent   = "backend"       # an agent profile the CLI already knows
runtime = "claude"        # claude | codex | gemini | copilot
cwd     = "~/src/api"

[desk.review]
group   = "work"
runtime = "codex"         # a second vendor, kept for cross-checking
cwd     = "~/src/api"

[desk.notes]
# `command` is the escape hatch: run anything verbatim, including a wrapper
# script of your own that already handles resume-vs-new.
command = "~/bin/desk notes"
cwd     = "~/notes"
```

## Keys

| | |
|---|---|
| `cmd-1` … `cmd-9` | jump to a desk |
| `cmd-r` | refresh the folder tree |
| `cmd-t` | move the tree above or below the desk list |
| `cmd-shift-m` | agent mail |
| `cmd-,` | settings |

Click a group header to collapse it, right-click to rename it.

## The bridge is a mailbox, not a protocol

Two agents from different companies hand work back and forth through an **append-only markdown thread**. A wire protocol is the obvious design and the wrong one:

- **Vendor-agnostic.** Anything with a headless mode can join. No adapter, no SDK, no coupling to anyone's release train.
- **The thread is the context.** Every headless invocation starts with no memory, so the file carries the conversation. This is why it appends and never replaces — overwriting a thread once destroyed a long exchange by replacing it with an answer from a session that had never read it.
- **Inspectable.** The exchange is a file you can read, diff and keep.
- **The responder is read-only**, enforced by the vendor's own flag rather than asked for politely: `claude -p --permission-mode plan`, `codex exec --sandbox read-only`. Where a vendor offers no such flag, Deskwork says so in the interface instead of implying a guarantee it cannot make.

Threads land in `~/.local/share/deskwork/mail/`. If you already have a handoff script, point Deskwork at it in `~/.config/deskwork/bridge.toml` and it will use yours instead.

## Status, honestly

It runs and it is useful. It is also early.

Working: desks, groups, the folder tree, the reader, the bridge, the cross-vendor meter, settings, first run.

Not built yet:

- No diff view. The reader shows a file, not what changed in it.
- No syntax highlighting.
- Desks die when the app quits; they do not outlive it.
- One terminal per desk, no splits.
- The meter is a summary strip, not a full pane. No per-desk breakdown or history chart yet.
- Live plan limits work for Claude only. No other CLI exposes remaining quota anywhere a local tool can read it.

## Reading

- [DESIGN.md](DESIGN.md) — the thesis, why existing tools cannot host it, the architecture, the milestones
- [spikes/terminal-throughput/RESULT.md](spikes/terminal-throughput/RESULT.md) — the measurement behind choosing SwiftTerm over writing a renderer

## Built on

[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) for the terminal, PDFKit for the reader. [libghostty](https://mitchellh.com/writing/libghostty-is-coming) is the intended engine later, once it ships a renderer — today `libghostty-vt` parses and tracks terminal state but does not draw.

## License

MIT. See [LICENSE](LICENSE).
