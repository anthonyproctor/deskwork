import AppKit
import DeskworkCore

/// The desk rail. Groups are collapsible and renameable; ungrouped desks sit on
/// top. Reports its own content height so the scroll view never clips the last
/// desk — a fixed estimate got that wrong as soon as group headers appeared.
final class SidebarView: NSView {
    var onSelect: ((Int) -> Void)?
    var onToggleGroup: ((String) -> Void)?
    var onRenameGroup: ((String) -> Void)?
    var onRemoveDesk: ((Int) -> Void)?
    var onRevealAgent: ((Int) -> Void)?
    var onMakeDefault: ((Int) -> Void)?

    private var buttons: [Int: NSButton] = [:]
    private var selected = -1
    private(set) var contentHeight: CGFloat = 0
    var collapsed: Set<String> = []

    override var isFlipped: Bool { true }   // lay out top-down inside the scroll view

    /// Per-desk activity, keyed by name. Set by the controller each tick.
    var activity: [String: DeskActivity] = [:] {
        didSet { if let i = lastSelected { select(i) } }
    }

    private(set) var lastDesks: [Desk]?
    private(set) var lastSelected: Int?

    func build(desks: [Desk]) {
        lastDesks = desks
        subviews.forEach { $0.removeFromSuperview() }
        buttons = [:]

        var order: [String?] = [nil]
        for d in desks where d.group != nil && !order.contains(where: { $0 == d.group }) {
            order.append(d.group)
        }

        var y: CGFloat = 10
        let w = max(bounds.width, 190)

        for g in order {
            let members = desks.enumerated().filter { $0.element.group == g }
            if members.isEmpty { continue }

            if let g {
                let isDown = !collapsed.contains(g)
                let h = GroupHeader(frame: NSRect(x: 10, y: y, width: w - 20, height: 20))
                h.configure(title: g, expanded: isDown)
                h.onClick = { [weak self] in self?.onToggleGroup?(g) }
                h.onRename = { [weak self] in self?.onRenameGroup?(g) }
                addSubview(h)
                y += 22
                if !isDown { y += 4; continue }
            }

            for (i, d) in members {
                let b = DeskButton(frame: NSRect(x: g == nil ? 12 : 22, y: y,
                                                 width: w - (g == nil ? 22 : 32), height: 22))
                b.onRemove = { [weak self] in self?.onRemoveDesk?(i) }
                b.onReveal = d.agent == nil ? nil : { [weak self] in self?.onRevealAgent?(i) }
                b.onMakeDefault = d.isDefault ? nil : { [weak self] in self?.onMakeDefault?(i) }
                b.runtimeName = d.runtime
                b.isDefaultDesk = d.isDefault
                b.title = d.name
                b.deskRuntime = d.runtime
                b.target = self; b.action = #selector(tapped(_:))
                b.tag = i
                b.bezelStyle = .inline
                b.isBordered = false
                b.contentTintColor = .labelColor
                b.alignment = .left
                b.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
                addSubview(b)
                buttons[i] = b
                y += 23
            }
            y += 6
        }

        contentHeight = y + 10
        frame = NSRect(x: 0, y: 0, width: w, height: contentHeight)
        if selected >= 0 { select(selected) }
    }

    @objc private func tapped(_ sender: NSButton) { select(sender.tag); onSelect?(sender.tag) }

    func select(_ i: Int) {
        lastSelected = i
        selected = i
        for (j, b) in buttons {
            let on = j == i
            let rt = (b as? DeskButton)?.deskRuntime ?? "shell"
            let bare = b.title
                .replacingOccurrences(of: "● ", with: "").replacingOccurrences(of: "○ ", with: "")
                .components(separatedBy: "  ").first ?? b.title

            // Vendor is an attribute of a desk, not a place to file it. Showing
            // it inline means groups can stay about PURPOSE — money, work,
            // school — instead of becoming a list of logos.
            let title = NSMutableAttributedString(
                string: (on ? "● " : "○ ") + bare,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 13, weight: on ? .bold : .regular),
                    // An inactive desk is still a thing you read. secondary
                    // washed the whole rail out.
                    .foregroundColor: on ? Theme.ui.accent : Theme.ui.text,
                ])
            if rt != "shell" {
                // Mark the home so the concept is visible, not just a menu item.
                let isHome = (b as? DeskButton)?.isDefaultDesk == true
                title.append(NSAttributedString(
                    string: "  " + rt + (isHome ? " home" : ""),
                    attributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
                        .foregroundColor: Theme.ui.dimText,
                    ]))
            }
            // The activity badge: a desk that answered while you were looking
            // somewhere else. AFTER the vendor label and in colour rather than a
            // new glyph in front, because the LEADING dot already means
            // "selected" and two dots with different meanings in one row is how
            // you get a badge nobody can read.
            switch activity[bare] ?? .quiet {
            case .quiet: break
            case .working:
                title.append(NSAttributedString(string: "  \u{25CC}", attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold),
                    .foregroundColor: Theme.ui.dimText]))
            case .ready:
                title.append(NSAttributedString(string: "  \u{25CF}", attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold),
                    .foregroundColor: NSColor.systemGreen]))
            }
            b.attributedTitle = title
        }
    }
}

/// Click to collapse, right-click (or the ⋯ menu) to rename.
extension SidebarView {
    /// Repaint after a light/dark flip. Every row builds its attributed string
    /// from the theme, so rebuilding them is the whole job.
    func restyle() {
        guard let d = lastDesks else { return }
        build(desks: d)
        if let i = lastSelected { select(i) }
    }
}

final class GroupHeader: NSView {
    var onClick: (() -> Void)?
    var onRename: (() -> Void)?
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 10, weight: .bold)
        label.textColor = Theme.ui.dimText
        label.frame = bounds
        label.autoresizingMask = [.width]
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }
    convenience init() { self.init(frame: .zero) }

    func configure(title: String, expanded: Bool) {
        label.stringValue = (expanded ? "▾ " : "▸ ") + title.uppercased()
    }

    override func mouseDown(with e: NSEvent) { onClick?() }
    override func rightMouseDown(with e: NSEvent) {
        let m = NSMenu()
        let it = NSMenuItem(title: "Rename Group…", action: #selector(rename), keyEquivalent: "")
        it.target = self
        m.addItem(it)
        NSMenu.popUpContextMenu(m, with: e, for: self)
    }
    @objc private func rename() { onRename?() }
}


/// Right-click a desk to remove it. The natural gesture, and it keeps the
/// distinction visible: removing a desk removes the shortcut, not the agent.
final class DeskButton: NSButton {
    var onRemove: (() -> Void)?
    var onReveal: (() -> Void)?
    var onMakeDefault: (() -> Void)?
    var runtimeName: String = ""
    var isDefaultDesk = false
    var deskRuntime: String = "shell"

    override func rightMouseDown(with e: NSEvent) {
        let m = NSMenu()
        if onReveal != nil {
            let r = NSMenuItem(title: "Reveal Agent Definition", action: #selector(reveal), keyEquivalent: "")
            r.target = self
            m.addItem(r)
            m.addItem(.separator())
        }
        if let _ = onMakeDefault {
            let g = NSMenuItem(title: "Make this the \(runtimeName) home",
                               action: #selector(makeDefault), keyEquivalent: "")
            g.target = self
            g.toolTip = "The home desk for a vendor is where Deskwork sends work that belongs "
                + "to the vendor rather than to one agent — creating an agent, managing them. "
                + "One per vendor. The home marked default also opens when Deskwork starts."
            m.addItem(g)
            m.addItem(.separator())
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
