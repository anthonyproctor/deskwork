import AppKit
import ColdfallCore

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

    private var rows: [Int: DeskRow] = [:]
    private var selected = -1
    private(set) var contentHeight: CGFloat = 0
    var collapsed: Set<String> = []

    override var isFlipped: Bool { true }   // lay out top-down inside the scroll view

    /// Per-desk status, keyed by name. Set by the controller each tick.
    var status: [String: DeskStatus] = [:] {
        didSet { for r in rows.values { r.status = status[r.deskName] ?? DeskStatus() } }
    }
    /// Advanced by the controller so a working desk's spinner turns.
    var tick = 0 { didSet { for r in rows.values { r.tick = tick } } }

    private(set) var lastDesks: [Desk]?
    private(set) var lastSelected: Int?

    func build(desks: [Desk]) {
        lastDesks = desks
        subviews.forEach { $0.removeFromSuperview() }
        rows = [:]

        // Size from the scroll view's VISIBLE width, not our own. The first
        // build runs before the window has finished sizing, so our own width
        // was a stale, narrower number — rows stopped a hundred points short of
        // the rail and the "2m" floated mid-row instead of sitting flush right.
        let visible = enclosingScrollView?.contentView.bounds.width ?? bounds.width
        let w = max(visible, 190)
        var y: CGFloat = 10

        // What this region is, before any of its rows.
        let title = SectionTitle("Desks")
        title.frame = NSRect(x: 14, y: y, width: w - 28, height: 16)
        title.translatesAutoresizingMaskIntoConstraints = true
        title.autoresizingMask = [.width]
        addSubview(title)
        y += 24

        var order: [String?] = [nil]
        for d in desks where d.group != nil && !order.contains(where: { $0 == d.group }) {
            order.append(d.group)
        }

        for g in order {
            let members = desks.enumerated().filter { $0.element.group == g }
            if members.isEmpty { continue }

            if let g {
                let isDown = !collapsed.contains(g)
                let h = GroupHeader(frame: NSRect(x: 10, y: y, width: w - 20, height: 20))
                h.autoresizingMask = [.width]
                h.configure(title: g, expanded: isDown)
                h.onClick = { [weak self] in self?.onToggleGroup?(g) }
                h.onRename = { [weak self] in self?.onRenameGroup?(g) }
                addSubview(h)
                y += 22
                if !isDown { y += 4; continue }
            }

            for (i, d) in members {
                let indent: CGFloat = g == nil ? 4 : 12
                let r = DeskRow(desk: d)
                r.frame = NSRect(x: indent, y: y, width: w - indent - 4, height: DeskRow.height)
                r.autoresizingMask = [.width]   // stretches with the rail; time stays flush right
                r.onClick = { [weak self] in self?.select(i); self?.onSelect?(i) }
                r.onRemove = { [weak self] in self?.onRemoveDesk?(i) }
                r.onReveal = d.agent == nil ? nil : { [weak self] in self?.onRevealAgent?(i) }
                r.onMakeDefault = d.isDefault || d.runtime == "shell"
                    ? nil : { [weak self] in self?.onMakeDefault?(i) }
                r.status = status[d.name] ?? DeskStatus()
                r.tick = tick
                addSubview(r)
                rows[i] = r
                y += DeskRow.height + 2
            }
            y += 8
        }

        contentHeight = y + 10
        frame = NSRect(x: 0, y: 0, width: w, height: contentHeight)
        if selected >= 0 { select(selected) }
    }

    /// The rail's real width is only known after the window lays out. Rebuild
    /// once it is, so the very first paint is not the narrow one.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let d = lastDesks { DispatchQueue.main.async { self.build(desks: d) } }
    }

    /// Track the visible width of the scroll view we sit in.
    ///
    /// A scroll view does NOT resize its document view when it resizes, so an
    /// autoresizing mask on this view does nothing. That was the second bug:
    /// the first build caught a stale narrow width and the time floated
    /// mid-row; stretching by mask then left the rows WIDER than the rail, and
    /// the time was laid out off-screen entirely. Following the clip view's
    /// frame keeps this view exactly as wide as what is visible, and the rows'
    /// own masks carry that down to them.
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: nil)
        guard let clip = superview as? NSClipView else { return }
        clip.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipResized),
                                               name: NSView.frameDidChangeNotification, object: clip)
    }

    /// Lay every child out to the current width, explicitly.
    ///
    /// Measured in a snapshot: the rail was correctly 240 wide while its rows
    /// were still 422 — built while the window was wider, and never shrunk.
    /// Rather than depend on autoresizing masks that evidently did not apply
    /// here, every width change re-lays the children out by hand. Rows keep a
    /// small right gutter; titles and group headers keep a margin matching
    /// their left inset.
    override func resizeSubviews(withOldSize old: NSSize) {
        for v in subviews {
            let w = v is DeskRow ? bounds.width - v.frame.minX - 4
                                 : bounds.width - 2 * v.frame.minX
            v.setFrameSize(NSSize(width: max(0, w), height: v.frame.height))
        }
    }

    @objc private func clipResized() {
        guard let clip = superview as? NSClipView else { return }
        let w = max(clip.bounds.width, 190)
        if abs(frame.width - w) > 0.5 { setFrameSize(NSSize(width: w, height: frame.height)) }
    }

    func select(_ i: Int) {
        lastSelected = i
        selected = i
        for (j, r) in rows { r.selected = (j == i) }
    }

    /// Repaint after a light/dark flip.
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
