# Changelog

What changed in each release, newest first. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/). Anything under **Unreleased** is on
`main` and arrives in the next release. In the app, **Project Coldfall ▸ What's New**
opens this file.

## [Unreleased]

### Added
- Rename a desk: right-click it, **Rename Desk…**. A running desk keeps running
  under the new name.
- Drag desks in the rail to reorder them. Dropping a desk among another group's
  desks, or on a group's header, moves it into that group. cmd-1 to cmd-9
  follow the new order.
- **Stop Desk…** on right-click ends a desk's processes and frees their memory.
  Click the desk to start it again.
- Each running desk shows its memory in the rail, measured across its whole
  process tree (the agent and every MCP server it started).
- Quick open (cmd-P): one box that finds a desk or a file.
- Layout toggles in the title strip for the rail, the reader and the usage
  meter (cmd-B, opt-cmd-B, cmd-J).
- A header over the terminal with split and close buttons.
- The reader sits in the window as a pane by default, and can be popped out.
- Markdown renders in the reader instead of showing its source.
- A real title strip: nothing sits under the window buttons, and
  double-clicking it fills the screen without hiding the dock.
- VS Code style explorer (EXPLORER title, the folder's name, file icons) and
  Cursor style desk rows (status, name, time since last output).

### Fixed
- The rail no longer repaints every row three times a second while nothing
  changes.
- Saving desks.toml dropped a desk's `model`, so any edit from the rail would
  have reset an ollama or grok desk to its default model.
- macOS stops asking for Documents access after every rebuild, when the local
  signing certificate is installed (`scripts/make-signing-cert.sh`).
- Every window follows the theme, not just the main two.

## [0.2.0] - 2026-09-20

Renamed from Deskwork to **Project Coldfall**. Existing config and history move
over on first launch, with a link left at the old paths.

### Added
- Fan-out: one question across many directories, priced before it runs, with a
  progress view and a cancel that stops the work.
- VS Code Dark Modern and Light Modern themes, dark by default.
- The rail shows when a desk has answered while you were looking elsewhere,
  and the dock badge counts them.
- Drag a file onto a desk, or paste a screenshot into one.
- An Edit menu, so copy and paste work everywhere.
- A contributor licence agreement (CLA.md).

### Fixed
- A fan-out slice could deadlock on a full pipe and sit forever.
- Codex vanished from the usage meter when its newest log had no limits in it.
- Scanning usage took 12 seconds; it is now cached.
- Theme settings in desks.toml were ignored, and saving desks wiped them.
- CI had been red for four commits unnoticed; the privacy guard now passes.

## [0.1.0] - 2026-09-20

First build.

### Added
- Desks: persistent agents in named terminals, started on first click, grouped
  and collapsible, configured in `~/.config/coldfall/desks.toml`.
- Runtimes for Claude, Codex, Gemini, Copilot, Grok, Ollama and plain shells.
- SSH hosts from `~/.ssh/config` offered as desks.
- A folder tree and a reader with tabs and syntax highlighting; files an agent
  writes open themselves.
- A cross-vendor usage meter with live plan limits.
- A mailbox bridge for handing work between vendors.
- Splits: up to four terminals per desk.
- Update from inside the app.
- Tests, CI, and guards that keep the core free of UI code and keep private
  paths out of the repo.

[Unreleased]: https://github.com/anthonyproctor/project-coldfall/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/anthonyproctor/project-coldfall/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/anthonyproctor/project-coldfall/releases/tag/v0.1.0
