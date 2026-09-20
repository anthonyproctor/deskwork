# Spike: can SwiftTerm keep up?

**Question.** The design picks Swift, which means SwiftTerm for the terminal.
SwiftTerm renders through CoreText, not the GPU. This project exists because a
slow terminal drove its author out of VS Code, so if SwiftTerm cannot keep up,
the terminal becomes the hardest problem in the build and the language choice
has to be revisited.

**Method.** A bare AppKit window hosting a `LocalProcessTerminalView`, running
`/bin/zsh -f`. The benchmark runs *inside* the terminal so pty backpressure does
the timing: a terminal that cannot drain output fast enough slows the process
writing it.

```sh
for n in 1 2 3; do /usr/bin/time -p sh -c 'seq 1 200000'; done
```

**Result** (macOS 26.6.1, M-series, 2026-09-19):

| Terminal | run 1 | run 2 | run 3 |
|---|---|---|---|
| SwiftTerm (CoreText) | 0.51s | **0.24s** | **0.23s** |
| Terminal.app | 0.27s | 0.27s | 0.27s |

**Verdict: SwiftTerm is fast enough.** At steady state it beats Terminal.app.
Run 1 is cold start. CoreText is not the bottleneck at this scale, so Swift
stands and M1 can treat the terminal as a dependency rather than a project.

**What this does not prove.** `seq` is plain ASCII on a single long stream. Real
agent output is coloured, unicode-heavy, and full of TUI redraws and cursor
addressing. This clears the bar that mattered — it is nowhere near xterm.js slow
— but a second pass with realistic output is worth doing before M3.

## Running it

```sh
cd spikes/terminal-throughput
swift build -c release
.build/release/DeskSpike
```
