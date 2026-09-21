// One desk in the rail, laid out the way Cursor lays out a task:
//
//     ✓  hub                         2m
//        claude · answered
//
// A status glyph, the name, how long ago it last did anything, and a line
// underneath saying what it is and what it is doing. The question the rail
// has to answer at a glance is "which of these needs me", and a green dot
// appended to the end of a name answered it badly — it was the thing the eye
// missed first.
//
// This replaces a row that was an NSButton whose title was a single
// attributed string. The name, vendor and badge were packed into it and then
// PARSED BACK OUT with string matching on every repaint — which is how an
// activity badge once shipped that never appeared at all. A row now holds its
// state as data and draws from it.

import AppKit
import ColdfallCore

/// What the rail needs to know about a desk, separate from its config.
struct DeskStatus: Equatable {
    var activity: DeskActivity = .quiet
    /// When it last wrote anything, for the "2m" on the right.
    var lastOutput: Date?
    /// Whether its process has been started this session.
    var running = false
    /// Resident memory of the desk's whole process tree, e.g. "940 MB".
    var memory: String?
}

final class DeskRow: NSView {

    var onClick: (() -> Void)?
    var onRemove: (() -> Void)?
    var onReveal: (() -> Void)?
    var onMakeDefault: (() -> Void)?
    var onRename: (() -> Void)?
    var onStop: (() -> Void)?
    var onMcp: (() -> Void)?
    /// Drag to reorder. Points are in the row's superview (the rail).
    var onDragMoved: ((NSPoint) -> Void)?
    var onDragEnded: ((NSPoint) -> Void)?

    let deskName: String
    private let runtime: String
    private let isDefault: Bool

    private let glyph = NSTextField(labelWithString: "")
    private let name = NSTextField(labelWithString: "")
    private let time = NSTextField(labelWithString: "")
    private let sub = NSTextField(labelWithString: "")

    var selected = false { didSet { if selected != oldValue { restyle() } } }
    /// Restyles only on a real change. The rail sets this for every row on
    /// every tick, and a full restyle each time was the rail repainting all
    /// of its rows about three times a second while nothing moved.
    var status = DeskStatus() { didSet { if status != oldValue { restyle() } } }
    /// Spinner frame, advanced by the rail's timer. Turns the glyph only.
    var tick = 0 {
        didSet {
            guard case .working = status.activity else { return }
            glyph.stringValue = Self.spin[tick % Self.spin.count]
            // The "now" / "2m" label ages without the status changing.
            let t = status.lastOutput.map(Self.ago) ?? ""
            if time.stringValue != t { time.stringValue = t }
        }
    }

    private var hovering = false { didSet { needsDisplay = true } }

    static let height: CGFloat = 40

    /// Quarter circles rather than braille. Braille dots rendered as a faint
    /// speck — near invisible in a snapshot of the real rail — and "working" is
    /// a state you need to be able to see. These carry the same visual weight
    /// as the ● and ○ beside them, and still read as turning.
    private static let spin = ["\u{25D0}", "\u{25D3}", "\u{25D1}", "\u{25D2}"]   // ◐◓◑◒

    init(desk: Desk) {
        deskName = desk.name
        runtime = desk.runtime
        isDefault = desk.isDefault
        super.init(frame: .zero)
        wantsLayer = true

        for f in [glyph, name, time, sub] {
            f.translatesAutoresizingMaskIntoConstraints = false
            f.lineBreakMode = .byTruncatingTail
            f.isSelectable = false
            addSubview(f)
        }
        glyph.alignment = .center
        glyph.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        time.alignment = .right
        time.setContentCompressionResistancePriority(.required, for: .horizontal)
        time.setContentHuggingPriority(.required, for: .horizontal)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            glyph.widthAnchor.constraint(equalToConstant: 16),
            glyph.centerYAnchor.constraint(equalTo: name.centerYAnchor),

            name.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 6),
            name.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            name.trailingAnchor.constraint(lessThanOrEqualTo: time.leadingAnchor, constant: -6),

            time.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            time.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),

            sub.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            sub.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            sub.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 1),
        ])

        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self))
        restyle()
    }
    required init?(coder: NSCoder) { nil }

    // MARK: - drawing

    override func draw(_ dirty: NSRect) {
        // A soft rounded fill for the selected and hovered rows, VS Code's
        // treatment, rather than a hard full-width band.
        let fill: NSColor? = selected ? Theme.ui.selected : (hovering ? Theme.ui.hover : nil)
        guard let fill else { return }
        fill.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 5, yRadius: 5).fill()
    }

    func restyle() {
        let ui = Theme.ui

        name.stringValue = deskName
        name.font = .systemFont(ofSize: 13, weight: selected ? .semibold : .regular)

        // Status first, so the eye finds "needs you" before anything else.
        let (g, gColor, state): (String, NSColor, String)
        switch status.activity {
        case .ready:
            // An agent "answered"; a shell just finished what it was running.
            (g, gColor, state) = ("\u{2713}", .systemGreen,
                                  runtime == "shell" ? "done" : "answered")      // ✓
        case .working:
            (g, gColor, state) = (Self.spin[tick % Self.spin.count], ui.accent, "working")
        case .quiet:
            (g, gColor, state) = status.running
                ? ("\u{25CF}", ui.dimText, "idle")                            // ●
                : ("\u{25CB}", ui.dimText.withAlphaComponent(0.6), "not started")  // ○
        }
        glyph.stringValue = g
        glyph.textColor = gColor

        // A finished desk you have not looked at gets a green name as well as
        // a green check: the word is what you scan, not a 12-point glyph.
        if case .ready = status.activity, !selected {
            name.textColor = .systemGreen
        } else {
            name.textColor = selected ? ui.text : ui.text.withAlphaComponent(0.92)
        }

        time.stringValue = status.lastOutput.map(Self.ago) ?? ""
        time.font = .systemFont(ofSize: 11)
        time.textColor = ui.dimText

        // What it is, then what it is doing. A plain shell has no vendor, so
        // it says so rather than implying one.
        var parts: [String] = []
        parts.append(runtime == "shell" ? "shell" : runtime + (isDefault ? " home" : ""))
        if runtime != "shell" || status.running { parts.append(state) }
        if let m = status.memory { parts.append(m) }
        sub.stringValue = parts.joined(separator: " \u{00B7} ")                  // ·
        sub.font = .systemFont(ofSize: 11)
        sub.textColor = ui.dimText

        needsDisplay = true
    }

    /// "now", "4m", "2h", "3d" — Cursor's compact form.
    static func ago(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        if s < 45 { return "now" }
        if s < 3600 { return "\(max(1, s / 60))m" }
        if s < 86_400 { return "\(s / 3600)h" }
        return "\(s / 86_400)d"
    }

    // MARK: - input

    override func mouseEntered(with e: NSEvent) { hovering = true }
    override func mouseExited(with e: NSEvent) { hovering = false }
    // A click selects; a drag of more than a few points reorders instead.
    private var downAt: NSPoint?
    private var dragging = false

    override func mouseDown(with e: NSEvent) { downAt = e.locationInWindow; dragging = false }

    override func mouseDragged(with e: NSEvent) {
        guard let start = downAt, onDragMoved != nil else { return }
        let p = e.locationInWindow
        if !dragging, hypot(p.x - start.x, p.y - start.y) > 4 { dragging = true; alphaValue = 0.45 }
        if dragging, let sv = superview { onDragMoved?(sv.convert(p, from: nil)) }
    }

    override func mouseUp(with e: NSEvent) {
        defer { downAt = nil; dragging = false; alphaValue = 1 }
        if dragging, let sv = superview { onDragEnded?(sv.convert(e.locationInWindow, from: nil)) }
        else if downAt != nil { onClick?() }
    }

    /// Refresh the "2m" label without a full restyle. Called by the rail.
    func refreshAge() {
        let t = status.lastOutput.map(Self.ago) ?? ""
        if time.stringValue != t { time.stringValue = t }
    }

    override func rightMouseDown(with e: NSEvent) {
        let m = NSMenu()
        if onReveal != nil {
            let r = NSMenuItem(title: "Reveal Agent Definition", action: #selector(reveal), keyEquivalent: "")
            r.target = self
            m.addItem(r); m.addItem(.separator())
        }
        if onMakeDefault != nil {
            let g = NSMenuItem(title: "Make this the \(runtime) home",
                               action: #selector(makeDefault), keyEquivalent: "")
            g.target = self
            g.toolTip = "The home desk for a vendor is where Project Coldfall sends work that belongs "
                + "to the vendor rather than to one agent. One per vendor. The home marked default "
                + "also opens when Project Coldfall starts."
            m.addItem(g); m.addItem(.separator())
        }
        let rn = NSMenuItem(title: "Rename Desk…", action: #selector(rename), keyEquivalent: "")
        rn.target = self
        m.addItem(rn)
        if onMcp != nil {
            let mc = NSMenuItem(title: "MCP Servers…", action: #selector(mcp), keyEquivalent: "")
            mc.target = self
            mc.toolTip = "Choose which of this folder's MCP servers this desk starts."
            m.addItem(mc)
        }
        if status.running, onStop != nil {
            let st = NSMenuItem(title: "Stop Desk…", action: #selector(stop), keyEquivalent: "")
            st.target = self
            st.toolTip = "Ends this desk's processes and frees their memory. Click the desk to start it again."
            m.addItem(st)
        }
        m.addItem(.separator())
        let d = NSMenuItem(title: "Remove Desk…", action: #selector(remove), keyEquivalent: "")
        d.target = self
        m.addItem(d)
        NSMenu.popUpContextMenu(m, with: e, for: self)
    }
    @objc private func remove() { onRemove?() }
    @objc private func rename() { onRename?() }
    @objc private func stop() { onStop?() }
    @objc private func mcp() { onMcp?() }
    @objc private func reveal() { onReveal?() }
    @objc private func makeDefault() { onMakeDefault?() }
}

/// A small uppercase section title — VS Code's "EXPLORER", Cursor's
/// "READY FOR REVIEW". Tells you what a region is without reading its rows.
final class SectionTitle: NSTextField {
    convenience init(_ text: String) {
        self.init(labelWithString: "")
        let a = NSAttributedString(string: text.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: Theme.ui.dimText,
            .kern: 0.6,
        ])
        attributedStringValue = a
        translatesAutoresizingMaskIntoConstraints = false
    }
}
