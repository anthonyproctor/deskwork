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
    var onRenameDesk: ((Int) -> Void)?
    var onStopDesk: ((Int) -> Void)?
    var onMoveDesk: ((Int, DeskDrop) -> Void)?
    /// A group dragged by its header: the group, and the group it now sits
    /// before (nil for last).
    var onMoveGroup: ((String, String?) -> Void)?
    var onSortDesks: (() -> Void)?
    /// The "needs you" line was clicked: go to this desk.
    var onJumpToWaiting: ((String) -> Void)?

    /// Group headers by the group they head, for drops onto a header.
    private var headers: [(group: String, view: GroupHeader)] = []
    /// Each named group's extent, header to last row, top to bottom.
    private var spans: [(group: String, minY: CGFloat, maxY: CGFloat)] = []
    /// The line showing where a dragged desk will land.
    private let dropLine = NSView()

    private var rows: [Int: DeskRow] = [:]
    private var selected = -1
    private(set) var contentHeight: CGFloat = 0
    var collapsed: Set<String> = []

    override var isFlipped: Bool { true }   // lay out top-down inside the scroll view

    /// Per-desk status, keyed by name. Set by the controller each tick.
    var status: [String: DeskStatus] = [:] {
        didSet {
            for r in rows.values { r.status = status[r.deskName] ?? DeskStatus() }
            let q = NeedsYou.queue(status.map {
                NeedsYou.Entry(name: $0.key, activity: $0.value.activity, lastOutput: $0.value.lastOutput)
            })
            // The line and the header counts change the layout, so a change
            // in who is waiting rebuilds. Not mid-drag: that would pull the
            // row out from under the pointer. The next tick catches up.
            if q != waiting, dropLine.superview == nil, let d = lastDesks {
                waiting = q
                build(desks: d)
            }
        }
    }
    /// Desks waiting on you, oldest first, as last drawn.
    private(set) var waiting: [String] = []
    /// Advanced by the controller so a working desk's spinner turns.
    var tick = 0 {
        didSet {
            for r in rows.values { r.tick = tick }
            // "2m" ages on its own; a few seconds' resolution is plenty.
            if tick % 8 == 0 { for r in rows.values { r.refreshAge() } }
        }
    }

    private(set) var lastDesks: [Desk]?
    private(set) var lastSelected: Int?

    func build(desks: [Desk]) {
        lastDesks = desks
        subviews.forEach { $0.removeFromSuperview() }
        rows = [:]
        headers = []
        spans = []

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

        if let text = NeedsYou.summary(waiting), let first = waiting.first {
            let strip = NeedsYouStrip(frame: NSRect(x: 10, y: y, width: w - 20, height: 26))
            strip.autoresizingMask = [.width]
            strip.configure(text)
            strip.onClick = { [weak self] in self?.onJumpToWaiting?(first) }
            addSubview(strip)
            y += 34
        }

        for g in DeskOrder.groups(desks) {
            let members = desks.enumerated().filter { $0.element.group == g }
            if members.isEmpty { continue }

            if let g {
                let isDown = !collapsed.contains(g)
                let h = GroupHeader(frame: NSRect(x: 10, y: y, width: w - 20, height: 20))
                h.autoresizingMask = [.width]
                // Folded, a group would hide a waiting desk entirely.
                let inside = isDown ? 0 : members.filter { waiting.contains($0.element.name) }.count
                h.configure(title: g, expanded: isDown, waiting: inside)
                h.onClick = { [weak self] in self?.onToggleGroup?(g) }
                h.onRename = { [weak self] in self?.onRenameGroup?(g) }
                h.onSort = { [weak self] in self?.onSortDesks?() }
                h.onDragMoved = { [weak self] p in self?.groupDragMoved(g, to: p) }
                h.onDragEnded = { [weak self] p in self?.groupDragEnded(g, at: p) }
                addSubview(h)
                headers.append((g, h))
                y += 22
                if !isDown { spans.append((g, h.frame.minY, y)); y += 4; continue }
            }
            let top = y - 22

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
                r.onRename = { [weak self] in self?.onRenameDesk?(i) }
                r.onStop = { [weak self] in self?.onStopDesk?(i) }
                r.onDragMoved = { [weak self] p in self?.dragMoved(from: i, to: p) }
                r.onDragEnded = { [weak self] p in self?.dragEnded(from: i, at: p) }
                r.status = status[d.name] ?? DeskStatus()
                r.tick = tick
                addSubview(r)
                rows[i] = r
                y += DeskRow.height + 2
            }
            if let g { spans.append((g, top, y)) }
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

    // MARK: - drag to reorder

    /// What a drop at `p` means: onto a header is the end of that group;
    /// onto a row is before or after it, by which half the pointer is in.
    private func drop(at p: NSPoint, from: Int) -> (DeskDrop, CGFloat)? {
        for h in headers where h.view.frame.insetBy(dx: -10, dy: -2).contains(p) {
            return (.endOfGroup(h.group), h.view.frame.maxY)
        }
        let ordered = rows.sorted { $0.value.frame.minY < $1.value.frame.minY }
        guard let first = ordered.first else { return nil }
        if p.y < first.value.frame.minY { return (.before(first.key), first.value.frame.minY) }
        for (i, r) in ordered where p.y < r.frame.maxY + 2 {
            if i == from { return nil }
            return p.y < r.frame.midY ? (.before(i), r.frame.minY) : (.after(i), r.frame.maxY)
        }
        let last = ordered.last!
        return last.key == from ? nil : (.after(last.key), last.value.frame.maxY)
    }

    private func dragMoved(from: Int, to p: NSPoint) {
        guard let (_, y) = drop(at: p, from: from) else { dropLine.removeFromSuperview(); return }
        dropLine.wantsLayer = true
        dropLine.layer?.backgroundColor = Theme.ui.accent.cgColor
        dropLine.frame = NSRect(x: 10, y: y - 1, width: bounds.width - 20, height: 2)
        if dropLine.superview == nil { addSubview(dropLine) }
        if let e = NSApp.currentEvent { autoscroll(with: e) }
    }

    private func dragEnded(from: Int, at p: NSPoint) {
        dropLine.removeFromSuperview()
        guard let (d, _) = drop(at: p, from: from) else { return }
        onMoveDesk?(from, d)
    }

    // MARK: - drag a group by its header

    /// Where a dragged group lands: before the first group whose middle is
    /// below the pointer, or last. Nil when that is where it already is.
    private func groupDrop(at p: NSPoint, moving g: String) -> (before: String?, y: CGFloat)? {
        guard let from = spans.firstIndex(where: { $0.group == g }) else { return nil }
        var target = spans.count
        for (k, s) in spans.enumerated() where p.y < (s.minY + s.maxY) / 2 { target = k; break }
        // Dropping just above itself or just below itself is no move.
        if target == from || target == from + 1 { return nil }
        if target == spans.count { return (nil, spans[spans.count - 1].maxY + 3) }
        return (spans[target].group, spans[target].minY - 4)
    }

    private func groupDragMoved(_ g: String, to p: NSPoint) {
        guard let (_, y) = groupDrop(at: p, moving: g) else { dropLine.removeFromSuperview(); return }
        dropLine.wantsLayer = true
        dropLine.layer?.backgroundColor = Theme.ui.accent.cgColor
        dropLine.frame = NSRect(x: 10, y: y - 1, width: bounds.width - 20, height: 2)
        if dropLine.superview == nil { addSubview(dropLine) }
        if let e = NSApp.currentEvent { autoscroll(with: e) }
    }

    private func groupDragEnded(_ g: String, at p: NSPoint) {
        dropLine.removeFromSuperview()
        guard let (before, _) = groupDrop(at: p, moving: g) else { return }
        onMoveGroup?(g, before)
    }

    /// Right-click on empty rail: the one action that is about the whole list.
    override func rightMouseDown(with e: NSEvent) {
        let m = NSMenu()
        let it = NSMenuItem(title: "Sort Desks A to Z", action: #selector(sortAll), keyEquivalent: "")
        it.target = self
        m.addItem(it)
        NSMenu.popUpContextMenu(m, with: e, for: self)
    }
    @objc private func sortAll() { onSortDesks?() }

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
    var onSort: (() -> Void)?
    var onDragMoved: ((NSPoint) -> Void)?
    var onDragEnded: ((NSPoint) -> Void)?
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

    func configure(title: String, expanded: Bool, waiting: Int = 0) {
        let s = NSMutableAttributedString(string: (expanded ? "▾ " : "▸ ") + title.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: Theme.ui.dimText,
        ])
        if waiting > 0 {
            s.append(NSAttributedString(string: "  ● \(waiting)", attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: NSColor.systemGreen,
            ]))
        }
        label.attributedStringValue = s
    }

    // A click folds the group; a drag of more than a few points moves it.
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

    override func rightMouseDown(with e: NSEvent) {
        let m = NSMenu()
        let it = NSMenuItem(title: "Rename Group…", action: #selector(rename), keyEquivalent: "")
        it.target = self
        m.addItem(it)
        let s = NSMenuItem(title: "Sort Desks A to Z", action: #selector(sort), keyEquivalent: "")
        s.target = self
        m.addItem(s)
        NSMenu.popUpContextMenu(m, with: e, for: self)
    }
    @objc private func rename() { onRename?() }
    @objc private func sort() { onSort?() }
}


/// Right-click a desk to remove it. The natural gesture, and it keeps the
/// distinction visible: removing a desk removes the shortcut, not the agent.

/// "2 need you: career, hub" at the top of the rail. Click to go to the one
/// that has waited longest.
final class NeedsYouStrip: NSView {
    var onClick: (() -> Void)?
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.14).cgColor
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .systemGreen
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 10, y: 5, width: frame.width - 20, height: 16)
        label.autoresizingMask = [.width]
        addSubview(label)
        toolTip = "Go to the desk that has waited longest (⌘0)"
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ text: String) { label.stringValue = "● " + text }

    override func mouseUp(with e: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
