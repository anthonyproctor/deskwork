# Deskwork

A terminal-first console for running several long-lived AI agents, across several
vendors, without losing track of what it costs.

Most tools treat the **file** as the unit of work, or the **thread**. If you keep
persistent specialists instead — each with its own memory, model and tools — then
neither fits. The agent is the unit. Call one a **desk**.

Deskwork gives you:

- **Desks, not threads.** Open, resume, fork and retire persistent agents. Each runs
  its own vendor CLI in a real pty, unmodified, so its config and memory just work.
- **A meter that is always visible.** Weekly and five-hour limits, per-desk spend,
  cache diagnostics. It shouts before you hit the wall, not after.
- **A router across vendors.** One window holding Claude, Codex, Gemini and Copilot
  can send the next job to whichever still has budget — and can have one review
  another's work.
- **A reader, not an editor.** Agents write the code; you read it. Diffs, syntax
  highlighting, images and PDFs. No LSP, no completions, no debugger.

Status: **design only.** Nothing is built. See [DESIGN.md](DESIGN.md) for the
architecture, the evidence behind it, and the milestones.

Built on [libghostty](https://mitchellh.com/writing/libghostty-is-coming) for
terminals and the [Agent Client Protocol](https://zed.dev/acp) for cross-vendor
agent work.
