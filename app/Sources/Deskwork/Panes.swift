// Splits — more than one terminal per desk.
//
// A desk is one agent. Real work wants a second view of the same directory:
// the agent in one pane, a shell in the other to look at what it just did.
//
// Panes are NOT desks, and the difference is the whole design. A desk is
// configured, named, metered and durable. A pane is a way of looking at one,
// has no config, and dies with the window. Pane 0 runs the desk's own command;
// every other pane is a plain login shell in the same cwd.
//
// One orientation per desk rather than a nested tree. Nesting doubles the
// interaction surface — which pane splits which way, how focus traverses,
// where a new pane lands — to serve a layout nobody has asked for yet. If
// somebody does, it is an issue with a thumbs-up on it.

import AppKit
import SwiftTerm
import DeskworkCore

// MARK: - a pane

/// A single terminal inside a desk, wrapped in a box that can show focus.
final class Pane {
    let term: LocalProcessTerminalView
    let box: PaneBox
    /// Pane 0 runs the desk's CLI. The rest are shells, and closing one is free.
    let isAgent: Bool
    private(set) var started = false

    init(isAgent: Bool) {
        self.isAgent = isAgent
        term = LocalProcessTerminalView(frame: .zero)
        term.translatesAutoresizingMaskIntoConstraints = false
        Theme.apply(to: term)
        box = PaneBox(term: term)
    }

    /// Launch the process. `command` is nil for a shell pane, which just lands
    /// in the directory and waits.
    func start(desk: Desk, command: String?) {
        guard !started else { return }
        started = true

        if let command {
            // A CLI can take several seconds to boot. Paint something
            // immediately, written straight to the view rather than through the
            // pty, so a blank screen never reads as "nothing happened".
            term.feed(text: "\u{1b}[2J\u{1b}[H"
                + "\u{1b}[36m●\u{1b}[0m starting \u{1b}[1m\(desk.name)\u{1b}[0m\r\n"
                + "\u{1b}[2m  \(command)\r\n"
                + "  in \(desk.resolvedCwd)\u{1b}[0m\r\n\r\n")
        }

        term.startProcess(executable: "/bin/zsh", args: ["-l"],
                          environment: Pane.environment(for: desk))

        // Land in the desk's directory, then launch its CLI. No `clear` here —
        // wiping the screen would throw away the only feedback there is.
        let dir = desk.resolvedCwd.replacingOccurrences(of: " ", with: "\\ ")
        let line = command.map { "cd \(dir) && \($0)\n" } ?? "cd \(dir)\n"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.term.send(txt: line)
        }
    }

    /// Deskwork hands its own environment to every desk, so anything the app
    /// inherited is inherited again by the agent. CLAUDECODE marks "you are
    /// already inside a Claude Code session" and makes a nested one refuse to
    /// start — which happens whenever Deskwork is launched from a terminal that
    /// is itself running an agent. Scrub it rather than depending on how the app
    /// was launched.
    static func environment(for desk: Desk) -> [String] {
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        let poison = ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SESSION_ID",
                      "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_BRIDGE_SESSION_ID",
                      "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN",
                      "CLAUDE_CODE_SESSION_ATTENDED", "CLAUDE_PID", "CLAUDE_EFFORT"]
        env.removeAll { entry in poison.contains(where: { entry.hasPrefix($0 + "=") }) }
        // Hooks and desk-scoped behaviour key off this, same as the shell wrapper.
        env.append("CLAUDE_DESK=\(desk.name)")
        env.append("DESKWORK=1")
        return env
    }
}

// MARK: - the focus ring

/// Holds one terminal and draws a ring around it when it has focus.
///
/// The ring only appears once a desk has more than one pane. A border around a
/// single pane is noise — there is nowhere else the keystrokes could go.
final class PaneBox: NSView {
    private let ring: CGFloat = 2
    var showsFocus = false { didSet { if showsFocus != oldValue { restyle() } } }
    var focused = true { didSet { if focused != oldValue { restyle() } } }
    private weak var term: NSView?

    init(term: NSView) {
        super.init(frame: .zero)
        self.term = term
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        addSubview(term)

        // Text butting against the frame is the first thing that makes a
        // terminal feel cheap, and the box rather than the terminal owns the
        // gap so the terminal's own background still fills it.
        let cfg = DeskConfig.themeSettings()
        let x = CGFloat(cfg.padX), y = CGFloat(cfg.padY)
        NSLayoutConstraint.activate([
            term.topAnchor.constraint(equalTo: topAnchor, constant: y),
            term.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -y),
            term.leadingAnchor.constraint(equalTo: leadingAnchor, constant: x),
            term.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -x),
        ])
        layer?.backgroundColor = Theme.current().skin.terminal.background.cgColor
    }
    required init?(coder: NSCoder) { nil }

    /// Dim the unfocused pane rather than only ringing the focused one. Ghostty
    /// does this (`unfocused-split-opacity`) and it reads faster: the eye finds
    /// the bright pane without looking for a border.
    private func restyle() {
        alphaValue = (showsFocus && !focused) ? 0.72 : 1.0
        needsDisplay = true
    }

    override func draw(_ dirty: NSRect) {
        Theme.current().skin.terminal.background.setFill()
        bounds.fill()
        guard showsFocus, focused else { return }
        let r = bounds.insetBy(dx: ring / 2, dy: ring / 2)
        NSColor.controlAccentColor.withAlphaComponent(0.8).setStroke()
        let p = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
        p.lineWidth = ring
        p.stroke()
    }
}

// MARK: - a desk's panes

/// One live desk: its panes, which one has focus, and the split view holding them.
final class DeskSession {
    let desk: Desk
    /// Every pane reports process exit to the same delegate, so a shell pane
    /// closing is handled the same way the agent's own exit is.
    weak var processDelegate: LocalProcessTerminalViewDelegate? {
        didSet { for p in panes { p.term.processDelegate = processDelegate } }
    }
    private(set) var panes: [Pane] = []
    private(set) var focused = 0
    /// Columns when vertical, rows when not. Set by the first split and kept.
    private(set) var isVertical = true

    /// The view to put on screen. A single pane is shown bare; a split view is
    /// only introduced once there is something to divide.
    let container = NSSplitView()

    init(desk: Desk) {
        self.desk = desk
        container.translatesAutoresizingMaskIntoConstraints = false
        container.dividerStyle = .thin
        container.isVertical = true
        panes.append(Pane(isAgent: true))
        rebuild()
    }

    /// The agent's terminal — where a routed command goes, regardless of which
    /// pane the user happens to be looking at.
    var agentTerm: LocalProcessTerminalView { panes[0].term }
    var focusedPane: Pane { panes[min(focused, panes.count - 1)] }
    var started: Bool { panes[0].started }

    func startIfNeeded() {
        panes[0].start(desk: desk, command: desk.launchCommand())
        for p in panes.dropFirst() { p.start(desk: desk, command: nil) }
    }

    /// Add a pane. The first split picks the orientation for the desk; later
    /// ones join it, because a desk has one axis rather than a tree.
    @discardableResult
    func split(vertical: Bool) -> Pane? {
        // Four is where panes stop being useful and start being a mosaic.
        guard panes.count < 4 else { return nil }
        if panes.count == 1 { isVertical = vertical; container.isVertical = vertical }
        let p = Pane(isAgent: false)
        p.term.processDelegate = processDelegate
        panes.insert(p, at: focused + 1)
        focused += 1
        rebuild()
        p.start(desk: desk, command: nil)
        return p
    }

    /// Close a pane, killing its process. Refuses the last one — a desk with no
    /// terminal is managed from the desk list, not from here.
    @discardableResult
    func closeFocused() -> Bool {
        guard panes.count > 1 else { return false }
        let p = panes.remove(at: focused)
        p.term.terminate()
        p.box.removeFromSuperview()
        focused = min(focused, panes.count - 1)
        rebuild()
        return true
    }

    func focus(_ i: Int) {
        guard panes.indices.contains(i) else { return }
        focused = i
        markFocus()
    }

    /// Move focus by one, wrapping. `cmd-[` and `cmd-]`.
    func cycleFocus(_ delta: Int) {
        guard panes.count > 1 else { return }
        focus((focused + delta + panes.count) % panes.count)
    }

    /// Focus whichever pane owns this terminal. Used when a click lands in one.
    func focusPane(owning term: TerminalView) -> Bool {
        guard let i = panes.firstIndex(where: { $0.term === term }) else { return false }
        focus(i)
        return true
    }

    func drop(term: TerminalView) {
        guard let i = panes.firstIndex(where: { $0.term === term }) else { return }
        guard panes.count > 1 else { return }   // the desk itself dying is handled above
        panes[i].box.removeFromSuperview()
        panes.remove(at: i)
        focused = min(focused, panes.count - 1)
        rebuild()
    }

    private func rebuild() {
        for v in container.arrangedSubviews { container.removeArrangedSubview(v) }
        for p in panes { container.addArrangedSubview(p.box) }
        markFocus()
    }

    private func markFocus() {
        let many = panes.count > 1
        for (i, p) in panes.enumerated() {
            p.box.showsFocus = many
            p.box.focused = (i == focused)
        }
    }
}
