import AppKit
import DeskworkCore

/// The desk rail. Groups are collapsible and renameable; ungrouped desks sit on
/// top. Reports its own content height so the scroll view never clips the last
/// desk — a fixed estimate got that wrong as soon as group headers appeared.
final class SidebarView: NSView {
    var onSelect: ((Int) -> Void)?
    var onToggleGroup: ((String) -> Void)?
    var onRenameGroup: ((String) -> Void)?

    private var buttons: [Int: NSButton] = [:]
    private var selected = -1
    private(set) var contentHeight: CGFloat = 0
    var collapsed: Set<String> = []

    override var isFlipped: Bool { true }   // lay out top-down inside the scroll view

    func build(desks: [Desk]) {
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
                let b = NSButton(frame: NSRect(x: g == nil ? 12 : 22, y: y,
                                               width: w - (g == nil ? 22 : 32), height: 22))
                b.title = d.name
                b.target = self; b.action = #selector(tapped(_:))
                b.tag = i
                b.bezelStyle = .inline
                b.isBordered = false
                b.contentTintColor = .secondaryLabelColor
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
        selected = i
        for (j, b) in buttons {
            let on = j == i
            b.contentTintColor = on ? .controlAccentColor : .secondaryLabelColor
            b.font = .monospacedSystemFont(ofSize: 13, weight: on ? .bold : .regular)
            let bare = b.title.replacingOccurrences(of: "● ", with: "").replacingOccurrences(of: "○ ", with: "")
            b.title = (on ? "● " : "○ ") + bare
        }
    }
}

/// Click to collapse, right-click (or the ⋯ menu) to rename.
final class GroupHeader: NSView {
    var onClick: (() -> Void)?
    var onRename: (() -> Void)?
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 9.5, weight: .semibold)
        label.textColor = .tertiaryLabelColor
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
