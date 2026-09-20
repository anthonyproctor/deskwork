# Contributing

## Where things go

| | |
|---|---|
| **Bug** | [Issues](../../issues/new/choose) — something behaves differently from how it reads |
| **Feature** | [Issues](../../issues/new/choose), after reading [ROADMAP.md](ROADMAP.md) |
| **Another runtime** | [Issues](../../issues/new/choose) — there is a template that asks the four questions that matter |
| **Half-formed idea, question, poll** | [Discussions](../../discussions) |
| **Security** | [Private advisory](../../security/advisories/new), not an issue |

**Voting is 👍 on the issue.** Priorities get ranked by reactions rather than by
who argues longest. Every priority in the roadmap is currently one person's
guess, so a reaction genuinely moves things.

## Security is not a formality here

Deskwork launches shells, reads local files, and hands a working directory to
agents from other companies. A bug in the meter shows a wrong number; a bug in
that surface does not. Report anything touching process execution, file access
or the cross-vendor bridge privately.

## Building

```sh
cd app && swift build -c release && ./.build/release/deskwork-test
```

macOS 13+, Command Line Tools is enough. **Xcode is not required and should not
become required** — that is a promise the README makes and CI enforces by
printing its toolchain. It is also why the test suite is a plain executable
rather than XCTest, which ships only with Xcode.

## Two rules the code is built around

**Never reimplement an agent.** Deskwork launches the vendor's own CLI in a real
pty. That is why your agent definitions, hooks, memory and model pins all work —
nothing is intercepting them. Anything that starts parsing or re-serving a
vendor's protocol is going the wrong way.

**`DeskworkCore` imports Foundation and nothing else.** That boundary is what
keeps a future Linux or Windows front end a UI project rather than a rewrite.
CI fails the build if a UI framework appears there.

## Things worth knowing before you change something

These are all bugs that already happened. Each cost an hour.

- `NSView` inherits `init()` from `NSResponder`, so `MyView()` can skip
  `init(frame:)` entirely and render an empty pane. Compiles, runs, shows
  nothing.
- An `NSStackView` used as a scroll view's `documentView` has no size of its
  own, and an unflipped one stacks content upward from the bottom.
- `String(format: "%-8s", swiftString)` needs a C string pointer and emits
  whatever is in memory otherwise.
- FSEvents returns a raw `char **` unless you set
  `kFSEventStreamCreateFlagUseCFTypes`.
- Config parsing must not cut at the first `#`: a command containing one is
  silently truncated, and a truncated command still runs.

The last one was found by a second AI agent reviewing the first one's tests,
using the bridge in this repo. If you are changing the parsers, add a test —
that is what caught the two bugs that followed it.

## Style

Comments explain **why**, especially where the obvious approach was rejected
and what went wrong. The code says what it does.
