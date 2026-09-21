# Project Coldfall: notes for coding agents

A macOS app for running persistent AI agents ("desks") side by side across
vendors. Swift and AppKit, built with SwiftPM, terminal from SwiftTerm.

## Layout

- `app/Sources/ColdfallCore`: pure logic. **Foundation only.** CI fails the
  build if it imports AppKit, SwiftUI, UIKit, PDFKit or SwiftTerm. Anything
  with a real way to go wrong (parsing, ranking, ordering, limits) lives here
  so it can be tested.
- `app/Sources/Coldfall`: the app. `main.swift` holds the Controller.
- `app/Sources/ColdfallCLI`: `coldfall-cli`.
- `app/Sources/ColdfallTests`: `coldfall-test`, a plain executable with
  `check` and `eq`. Not XCTest, so it runs on any toolchain.

## Build, test, look

```sh
cd app
swift build -c release
./.build/release/coldfall-test
./.build/release/Coldfall --snapshot /tmp/shot.png            # render the window, start nothing
./.build/release/Coldfall --snapshot /tmp/shot.png --palette hub   # plus quick open
./.build/release/Coldfall --snapshot /tmp/shot.png --desks demo.toml  # made-up desks, not the real ones
./.build/release/Coldfall --snapshot /tmp/shot.png --reader-hidden    # as if the reader were toggled off
../scripts/build-app.sh                                        # ~/Applications/Project Coldfall.app
../scripts/release-zip.sh                                      # the zip a GitHub release ships
```

A release zip always comes from `scripts/release-zip.sh`, never a hand-made
zip of the local bundle. The local bundle carries the builder's home path (in
Info.plist and in debug symbols) and a personal signing certificate; the
script strips all of it and refuses to finish if any home path is left.

`COLDFALL_SNAPSHOT_DEBUG=1` prints measured frames with a snapshot.

## Rules

- **Never quit or relaunch a running Project Coldfall.** The person you are
  working for is probably running you inside it, so quitting it ends the
  conversation. Use `--snapshot` to see UI changes, build the bundle, and ask
  them to relaunch.
- **Render and look before calling UI work done.** Take a snapshot and read
  the image. A clean build proves nothing about layout.
- **Check CI after every push** (`gh run list --limit 1`). Run the CI steps
  locally first: build, test, the core import guard, and the privacy guard.
- **Assert on scripted edits.** A search-and-replace that matches nothing
  fails silently. Check the match count is exactly one.
- **Tests go in the core.** If logic you need to test sits in the app target,
  move it to ColdfallCore.
- **Nothing private in the repo.** CI rejects committed paths under a real
  home directory. Test fixtures use neutral paths such as `/srv/demo`.
- Tests must not write to the real `~/.local/share/coldfall` or
  `~/.config/coldfall`. Point the overridable roots at a temp directory.
- Record user-visible changes under **Unreleased** in `CHANGELOG.md`.
