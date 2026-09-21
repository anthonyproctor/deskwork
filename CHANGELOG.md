# Changelog

What changed in each release, newest first. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/). Anything under **Unreleased** is on
`main` and arrives in the next release. In the app, **Project Coldfall ▸ What's New**
opens this file.

## [Unreleased]

### Added
- A daily update check. The title strip shows a link when a newer release is
  out. The check sends a random ID made on your Mac, the app version and the
  macOS version, which is also how installs are counted; nothing else, and
  the server keeps no list of IDs. You're told before the first check, and it
  can be turned off in Settings. See "What Coldfall sends" in the README.

### Changed
- Settings is split into Desks, Appearance, Agents and Updates tabs, sized to
  fit the screen. It used to be one column taller than a laptop display.

### Fixed
- Double-clicking the title strip a second time now puts the window back.
- Release downloads no longer contain the path of the folder they were built
  in. The zips for 0.1.0, 0.2.0 and 0.3.0 have been replaced with cleaned
  copies of the same builds. New releases are made with
  `scripts/release-zip.sh`, which checks for this before it finishes.

## [0.3.0] - 2026-09-21

Desks pick up where they left off, and the rail shows which ones are waiting
on you.

### Added
- Rename a desk: right-click it, **Rename Desk…**. A running desk keeps running
  under the new name.
- Drag desks in the rail to reorder them. Dropping a desk among another group's
  desks, or on a group's header, moves it into that group. cmd-1 to cmd-9
  follow the new order.
- **Needs you**: when desks are waiting on you, a line at the top of the rail
  names them, oldest wait first. Click it, or press cmd-0, to go to the one
  that has waited longest. A folded group shows how many of its desks are
  waiting, so folding one no longer hides them.
- Desks Coldfall starts itself now pick up where they left off. A Claude desk
  reopens its own conversation (the newest one carrying the desk's name), and
  a Codex desk reopens its latest conversation in the desk's folder. Desks
  with their own command still run exactly that command.
- Drag a group's header to move the whole group, desks and all.
- **Sort Desks A to Z**: right-click a group header or empty space in the rail,
  or use the Desks menu. Groups sort by name, and so do the desks in each
  group. Ungrouped desks stay on top. It sorts once, so you can still drag
  afterwards.
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
- Hiding the reader no longer leaves a dark line down the terminal where its
  edge used to be.
- A stopped desk no longer leaves a `<defunct>` process behind until the app
  quits.
- **Stop Desk…** now ends the agent too. It used to end only the shell, which
  ignores that signal, so the agent kept running unseen, still holding its
  memory, and starting the desk again opened the same conversation a second
  time. Closing a split pane had the same problem.
- The stop and update dialogs said every desk starts fresh. They now say what
  actually comes back.
- cmd-1 to cmd-9 now match the rail even when a group's desks are scattered
  through `desks.toml`.
- Saving `desks.toml` no longer stacks another copy of the header comment at
  the top each time.
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

[Unreleased]: https://github.com/anthonyproctor/project-coldfall/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/anthonyproctor/project-coldfall/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/anthonyproctor/project-coldfall/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/anthonyproctor/project-coldfall/releases/tag/v0.1.0
