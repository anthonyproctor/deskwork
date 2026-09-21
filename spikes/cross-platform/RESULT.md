# Spike: can Project Coldfall be cross-platform?

**Question.** Project Coldfall is macOS-only because it uses SwiftTerm and PDFKit. For an
open-source project that is an adoption ceiling. Is there a Rust stack that gives
a GPU-accelerated, embeddable terminal widget on macOS, Linux and Windows?

Run 2026-09-20.

## Answer: yes on the toolchain, unproven at runtime

**`iced` + `iced_term` + `wgpu` builds and launches with Command Line Tools alone.**
13MB release binary, window opens. iced renders through wgpu, which compiles
shaders at runtime, so no platform shader compiler is needed at build time.

**`gpui` is blocked on macOS.** Its build script shells out to `xcrun metal`, and
that compiler ships only with full Xcode, not Command Line Tools:

```
error: gpui@0.2.2: metal shader compilation failed:
  xcrun: error: unable to find utility "metal", not a developer tool or in PATH
```

For an open-source project that is a ~15GB tax on every macOS contributor.

## The widget ecosystem is thinner than it looks

| crate | version | last updated | downloads | verdict |
|---|---|---|---|---|
| `alacritty_terminal` | 0.26.0 | 2026-04-06 | 1.6M | solid — everyone's VT engine |
| `iced_term` | 0.8.0 | 2026-03-27 | 24K | **the only live widget** |
| `gpui` (crates.io) | 0.2.2 | 2025-10-22 | 290K | 11 months behind Zed's own tree |
| `gpui-terminal` | 0.1.0 | 2025-12-24 | 2K | one release, needs Xcode |
| `egui-terminal` | 0.1.0 | **2023-07-29** | 1.6K | pinned to egui 0.22 vs current 0.36 |

Everyone publishes the VT *parser*. Almost nobody publishes a maintained
*widget*. Same shape as `libghostty-vt`, which parses and tracks state but does
not draw.

## What this spike did NOT establish

**Throughput.** Three attempts failed to drive input into the widget
programmatically, and the window ended up blocked at 0% CPU with the main thread
parked in the iced event loop — the async runtime never started. That is a
harness bug, not evidence about the crate, and it is recorded here as unknown
rather than as a result.

It is worth one honest comparison though: SwiftTerm went from nothing to a
working, benchmarked terminal in a single build. `iced_term` did not, in three.
That is weak evidence about relative maturity, not proof.

## Open problem: the reader

PDFKit has no Rust equivalent of comparable quality. Opening a PDF inline is one
of the few things Project Coldfall does that Zed still cannot, so a port has to answer
this rather than drop it.

## Recommendation

Do not rewrite yet. Formalise the **portable core** instead: desk config, usage
scanning, quota reading and the mailbox bridge are already nothing but file
reads and CLI invocations, with no macOS dependency of any kind. Roughly a third
of the codebase is portable today by construction. Keeping it that way means a
future Linux/Windows front end is a UI project rather than a rewrite, and it
costs nothing now.
