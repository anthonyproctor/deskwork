# Deskwork

**A terminal-first console for running several long-lived AI agents, across several vendors, without losing track of what it costs.**

macOS · Swift · early, but it runs

[![build and test](https://github.com/anthonyproctor/deskwork/actions/workflows/ci.yml/badge.svg)](https://github.com/anthonyproctor/deskwork/actions/workflows/ci.yml)

---

## The idea

Every coding tool picks one of two units of work. VS Code and its descendants treat the **file** as the unit. Zed's agent panel, Copilot and Cursor treat the **thread** as the unit — a conversation starts, does a job, gets thrown away.

Once you have been living in this stuff for a few months, neither fits. You stop having conversations and start keeping **specialists**: one for your infrastructure, one for a particular client, one for your notes. Each has its own system prompt, its own memory on disk, its own pinned model. The session is disposable. The specialist is not — it has been accumulating judgement for months, and you don't re-explain your situation to it.

Deskwork calls one of those a **desk**, and makes the desk the unit.

## What it does

**Desks, not threads.** Each desk owns one or more long-lived terminals running the vendor's own CLI. Switching desks swaps which terminal is visible; the rest keep running. Come back an hour later and it is mid-thought where you left it.

**It never reimplements an agent.** Deskwork launches `claude`, `codex`, `gemini` or `copilot` in a real pty. Your agent definitions, hooks, memory files and model pins all apply, because nothing is intercepting them. This is the point: ACP-based editors run a Claude Code bundled inside the Agent SDK rather than the CLI on your machine, which is why your own agents do not exist there.

**Drag a file onto a desk and its path is typed.** SwiftTerm has no drag support, so this had to be added — and in a tool built for talking to agents it is not a nicety: showing an agent a screenshot means handing it a path, and there was no way to produce one without leaving the app. Paths are escaped for the shell, so `report (final).pdf` arrives intact.

**Pasting a screenshot works too.** `cmd-ctrl-shift-4` puts an image on the clipboard and nowhere else; paste it into a desk and Deskwork writes it to `~/.local/share/deskwork/pasted/` and types that path instead. Pasting text is untouched, and a file copied in Finder still pastes as a path the normal way.

**It tells you when a desk answered.** The point of desks is running several agents at once, which means you are never watching more than one of them — so a desk that finishes while you are elsewhere gets a **green dot** in the rail, and the Dock icon carries a count of how many are waiting. A desk mid-thought shows a dim ring instead, so "working" and "done" are not the same signal.

No CLI announces that it has finished answering; all that reaches Deskwork is bytes on a pty, so "finished" is inferred from bytes stopping for two seconds. Looking at the desk is the only thing that clears the dot — not hovering, not bringing the app forward. A badge that clears itself is worse than none, because you stop trusting it was ever set.

**Splits, when one terminal is not enough.** `cmd-d` and `cmd-shift-d` give a desk a second pane: the agent in one, a shell in the other to look at what it just did. Pane 0 is the agent and confirms before you close it; the rest are login shells in the same directory and close for free. A desk keeps one axis and stops at four panes, because past that it is a mosaic rather than a workspace.

**A folder tree and a reader, with tabs.** Agents write, you read. Files an agent touches **open themselves** — you cannot pre-open a file when you do not know which one it will edit. Those tabs are transient and render italic, like a preview tab, and recycle past four so a busy desk cannot bury you; clicking one pins it. Each tab watches its file and refreshes in place. PDFs, images and text, with shallow syntax highlighting. Read-only is what keeps the reader small — and why a PDF opens here at all.

**A meter that spans vendors.** The strip along the bottom shows how much of each vendor's plan you have left, side by side:

```
codex wk 19% → mon 8pm · 5h 0%     claude wk 3% → sat 11am · 5h 3%
```

Each vendor gives this up differently, so Deskwork meets each where it is. **Codex** writes quota into its own session rollout, so it needs nothing. **Claude** tells only its statusline, so Deskwork offers to *be* that statusline — a recorder captures the numbers and then chains to whatever statusline you already had, printing its output unchanged. **Anything else** can join by dropping `~/.local/share/deskwork/limits/<vendor>.json`; no code change needed.

With real quota on both sides the router stops guessing from token share and says the actionable thing: *"claude 84% used, codex only 19% — send the next one to codex."* It stays quiet when there is no real gap.

Click the strip (or `cmd-shift-u`) for the detail: quota bars per vendor, which desk ate what, and a fourteen-day history split by vendor.

**A tree you can rearrange.** Drag files into folders, Finder-style, including from Finder itself. Moving files is the one destructive thing the window can do, so it names what moves and where before doing it, refuses a folder into its own subtree, never overwrites on a name collision, and `cmd-z` puts the last move back. Agents are writing in that tree — a silent move is how you lose work you cannot find again.

**Desks it finds for you.** Agent definitions in `.claude/agents` and `.github/agents` are offered as desks, one click each — creating an agent surfaces a desk. So are **Codex profiles** from `~/.codex/config.toml`, because Codex has no agent definitions; its analogue is a named profile selected with `-p`, and Deskwork labels them as profiles rather than pretending they are the same thing. So are hosts from `~/.ssh/config`: a remote box is exactly what a desk is for, and it connects by alias so ssh applies your own identity files and jump hosts.

Each desk shows which vendor is behind it, and each runtime can have a **home** — the general desk it opens on and where vendor-owned work gets routed. A Claude home and a Codex home coexist.

**A cross-vendor bridge.** Put a question to an agent from a different company and get an answer back with the whole conversation as context, or fan the same question across a dozen directories at once and get one reconciled reply. It is a mailbox, not a protocol — see below.

## Requirements

- macOS 13 or later
- A Swift toolchain. **Xcode is not required**; Command Line Tools is enough:
  ```sh
  xcode-select --install
  ```
- At least one agent CLI, though the app opens fine without any: Claude Code, Codex, Gemini CLI, GitHub Copilot CLI, Grok CLI, or Ollama for a local model

## Install

Download the latest `Deskwork.app.zip` from [Releases](https://github.com/anthonyproctor/deskwork/releases), unzip it, and drag it to Applications.

It is **not notarised**, so the first launch is blocked with "Apple could not verify Deskwork is free of malware." That is Gatekeeper telling you the truth: nobody has paid Apple $99 to vouch for this binary. To open it anyway:

```sh
xattr -d com.apple.quarantine /Applications/Deskwork.app
```

Or right-click the app, choose **Open**, and confirm once. If you would rather not do either, build it yourself — the source is right here, and that is the better habit:

```sh
git clone https://github.com/anthonyproctor/deskwork
cd deskwork
./scripts/build-app.sh          # builds ~/Applications/Deskwork.app
open ~/Applications/Deskwork.app
```

Pass a directory to put it elsewhere: `./scripts/build-app.sh /Applications`.

First launch writes a working config from whichever CLIs it finds and shows a welcome screen explaining what it found. There is nothing to set up by hand.

`deskwork-cli` ships inside the bundle at `Deskwork.app/Contents/MacOS/deskwork-cli` — the core, headless, JSON on stdout. See [docs/FORMATS.md](docs/FORMATS.md).

To run it as a plain binary during development: `cd app && swift build -c release && .build/release/Deskwork`.

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
runtime = "claude"        # claude | codex | gemini | copilot | grok | ollama
cwd     = "~/src/api"

[desk.review]
group   = "work"
runtime = "codex"         # a second vendor, kept for cross-checking
cwd     = "~/src/api"

[desk.local]
runtime = "ollama"        # runs on your machine; nothing leaves it
model   = "llama3"
cwd     = "~/src/api"

[desk.notes]
# `command` is the escape hatch: run anything verbatim. A wrapper script of
# your own, or a model on another box:
#   command = "ssh box 'ollama run llama3'"
command = "~/bin/desk notes"
cwd     = "~/notes"
```

## Look

VS Code Dark Modern and Light Modern, JetBrains Mono at 14, block cursor, and real padding between the text and the frame. Deskwork exists because a terminal was not good enough, so this is not a cosmetic concern — it is most of the product.

**The chrome and the terminal are one theme, not two.** A Gruvbox terminal inside a stock-grey AppKit sidebar looks like two programs sharing a window. The sidebar, file tree, reader and status strip all take their colours from the same skin the terminal does.

It **follows the system** light/dark switch by default, repainting live — including the terminals, which hold concrete colours rather than semantic ones and so do not follow on their own. Pin it if you would rather it stayed put; a terminal you read all day is not something everyone wants flipping at sunset.

The unfocused pane dims rather than relying on the focus ring alone: the eye finds the bright pane without hunting for a border.

```toml
[theme]
palette   = "vscode"      # vscode | gruvbox | nord | solarized
mode      = "system"      # system | light | dark
font      = "JetBrainsMono Nerd Font Mono"
size      = 14
padding_x = 12
padding_y = 10
```

`vscode` and `gruvbox` have both a light and a dark skin. `nord` and `solarized` are dark only and stay dark in light mode rather than inventing a light variant badly.

A font that is not installed falls back to the next one that is, and an unrecognised palette falls back to the default. Neither can produce an empty pane.

## Keys

| | |
|---|---|
| `cmd-1` … `cmd-9` | jump to a desk |
| `cmd-d` / `cmd-shift-d` | split the desk right / down |
| `cmd-w` | close the focused pane |
| `cmd-[` / `cmd-]` | move between panes |
| `cmd-r` | refresh the folder tree |
| `cmd-z` | undo — the last file move, or your typing if you are in a text field |
| `cmd-shift-a` | agents |
| `cmd-t` | move the tree above or below the desk list |
| `cmd-shift-u` | usage detail |
| `cmd-shift-m` | agent mail |
| `cmd-,` | settings |
| `cmd-opt-shift-u` | update Deskwork from source |

Click a group header to collapse it, right-click to rename it.

## The bridge is a mailbox, not a protocol

Two agents from different companies hand work back and forth through an **append-only markdown thread**. A wire protocol is the obvious design and the wrong one:

- **Vendor-agnostic.** Anything with a headless mode can join. No adapter, no SDK, no coupling to anyone's release train.
- **The thread is the context.** Every headless invocation starts with no memory, so the file carries the conversation. This is why it appends and never replaces — overwriting a thread once destroyed a long exchange by replacing it with an answer from a session that had never read it.
- **Inspectable.** The exchange is a file you can read, diff and keep.
- **The responder cannot write**, enforced by the vendor's own flag rather than asked for politely: `claude -p --permission-mode plan`, `codex exec --sandbox read-only`. Where a vendor offers no such flag, Deskwork says so in the interface instead of implying a guarantee it cannot make.

### Read-only is not private

This is the part worth reading twice. Those flags stop the other vendor **writing**. They do nothing about **reading**. A responder runs with a working directory, and it can read every file underneath it — in testing, a single review sent Codex grepping through the entire workspace, transcripts included.

So the directory you point it at is a privacy boundary, not a convenience. Deskwork shows you that path before you send, and asks once per vendor per launch to confirm it. Narrow it with `scope`:

```toml
# ~/.config/deskwork/bridge.toml
scope = "~/src/api"     # the responder sees only this, not your whole home
```

If the tree holds anything you would not hand to that vendor, set `scope` before you send.

**Or send it to a local model instead.** `ollama` is a first-class runtime, and a local responder reads your files without anything leaving the machine. The panel says which you are talking to, and only asks you to confirm exposure for the hosted ones — because for a local one there is none.

### Fanning out

The mailbox does one question and one answer, which is right for a second opinion and wrong for a review. **Fan out…** asks the same question of several directories in parallel, then once more with every answer as context — that last step is the deliverable, because N opinions you have to reconcile yourself is worse than none.

A run is a directory of ordinary threads, not a graph in a config file:

```
mail/fanout-2026-09-20-143022-review/
  00-ask.md          the question, and what it was sliced across
  01-src-api.md      one thread per slice, same format as any other
  02-src-web.md
  merge.md           every answer as context, one reconciled reply
```

Two things make this worth doing here rather than in an orchestration framework:

- **It knows what it costs.** N slices is N+1 invocations, and Deskwork is the only thing in the loop reading your real remaining quota. The sheet prices the run before you press Run, refuses outright when the week cannot pay for it, and names a vendor with room instead. It never moves the work for you — that is a decision, not an optimisation.
- **It exposes less, not more.** One responder pointed at a whole tree reads everything. Twelve responders each pointed at one subdirectory read one twelfth each. Slicing tightens the privacy boundary described above.

Build output, `node_modules`, `.git` and friends are skipped; a slice spent being told there is nothing in `node_modules` is a wasted invocation.

Threads land in `~/.local/share/deskwork/mail/`. If you already have a handoff script, point Deskwork at it in `~/.config/deskwork/bridge.toml` and it will use yours instead.

## Status, honestly

It runs and it is useful. It is also early.

Working: desks, groups, the folder tree, the reader, the bridge, the cross-vendor meter, settings, first run.

Not built yet:

- No diff view. The reader shows a file, not what changed in it.
- No syntax highlighting.
- Desks die when the app quits and come back as new sessions, not resumed ones.
- Live quota works for Claude and Codex. Gemini and Copilot expose nothing locally, so they show consumption only.

## Updating

`cmd-opt-shift-u`. Deskwork pulls, rebuilds from source and relaunches itself — no terminal, no remembering three commands. It records where it was built from at build time rather than guessing, so a bundle shipped without source says so instead of inventing a path.

A failed build never relaunches. The running app stays exactly as it was and the log tells you why.

**A relaunch is not free**, and the update window says so before you press it: it names the desks about to end. A desk comes back when you reopen it, but as a **new session** — nothing passes a resume flag to the vendor's CLI, so the desk returns and whatever it was in the middle of does not. That matters most to the person using Deskwork to work *and* to upgrade Deskwork, which is everybody who has it. Making desks genuinely resume is tracked as an issue.

## Tests

```sh
cd app && swift build -c release && ./.build/release/deskwork-test
```

Plain executable, not XCTest — XCTest ships with Xcode, and this project builds on Command Line Tools alone. A suite that reintroduced a 15GB dependency would defeat the point.

Every test is a regression for a fault that actually shipped, not an invented case.

## Contributing

Bugs and features in [Issues](../../issues/new/choose); ideas, questions and polls in [Discussions](../../discussions). **👍 on an issue is the vote** — priorities are ranked by reactions, and every priority in the roadmap is currently one person's guess.

Security touching process execution, file access or the bridge goes to a [private advisory](../../security/advisories/new) rather than an issue.

See [CONTRIBUTING.md](CONTRIBUTING.md), which includes the five AppKit and parsing traps that have each already cost an hour.

## Reading

- [DESIGN.md](DESIGN.md) — the thesis, why existing tools cannot host it, the architecture, the milestones
- [ROADMAP.md](ROADMAP.md) — what is next, what is deliberately not being built, and what would change the plan
- [spikes/terminal-throughput/RESULT.md](spikes/terminal-throughput/RESULT.md) — the measurement behind choosing SwiftTerm over writing a renderer

## Built on

[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) for the terminal, PDFKit for the reader. [libghostty](https://mitchellh.com/writing/libghostty-is-coming) is the intended engine later, once it ships a renderer — today `libghostty-vt` parses and tracks terminal state but does not draw.

## License

MIT. See [LICENSE](LICENSE).
