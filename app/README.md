# Deskwork — M1, the desk switcher

A window with your desks down the left and one long-lived terminal each. Switching
desks swaps which terminal is visible; the others keep running.

Deskwork does not reimplement any agent. Each desk launches the vendor's own CLI in
a real pty, so that CLI's config, hooks, memory and model pins apply untouched.

## Build and run

```sh
swift build -c release
.build/release/Deskwork
```

Requires macOS 13+ and the Swift toolchain (Command Line Tools is enough; Xcode is
not needed).

## Configure

`~/.config/deskwork/desks.toml`:

```toml
[desk.shell]
# A plain shell first means opening the app costs nothing.
command = "exec zsh -l"
cwd = "~"

[desk.notes]
agent   = "research-copilot"
runtime = "claude"          # claude | codex | gemini | copilot
cwd     = "~/notes"

[desk.api]
# `command` is the escape hatch: run anything verbatim, including your own
# wrapper script that already handles resume-vs-new.
command = "~/bin/desk api"
cwd     = "~/src/api"
```

Nothing starts until you click a desk.

## Keys

`cmd-1` … `cmd-9` jump between the first nine desks.

## What M1 does not do yet

- No file tree
- No reader pane, so no diffs and no PDFs
- Desks die when the app quits; they do not outlive it
- One terminal per desk, no splits

See [../DESIGN.md](../DESIGN.md) for where this is going.
