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
struct DeskStatus {
    var activity: DeskActivity = .quiet
    /// When it last wrote anything, for the "2m" on the right.
    var lastOutput: Date?
    /// Whether its process has been started this session.
    var running = false
}

final class DeskRow: NSView {

    var onClick: (() -> Void)?
    var onRemove: (() -> Void)?
    var onReveal: (() -> Void)?
    var onMakeDefault: (() -> Void)?

    let deskName: String
    private let runtime: String
    private let isDefault: Bool

    private let glyph = NSTextField(labelWithString: "")
    private let name = NSTextField(labelWithString: "")
    private let time = NSTextField(labelWithString: "")
    private let sub = NSTextField(labelWithString: "")

    var selected = false { didSet { if selected != oldValue { restyle() } } }
    var status = DeskStatus() { didSet { restyle() } }
    /// Spinner frame, advanced by the rail's timer.
    var tick = 0 { didSet { if case .working = status.activity { restyle() } } }
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
    override func mouseDown(with e: NSEvent) { onClick?() }

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
        let d = NSMenuItem(title: "Remove Desk…", action: #selector(remove), keyEquivalent: "")
        d.target = self
        m.addItem(d)
        NSMenu.popUpContextMenu(m, with: e, for: self)
    }
    @objc private func remove() { onRemove?() }
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
