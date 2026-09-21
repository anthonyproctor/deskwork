import AppKit
import ColdfallCore

/// One entry in the tree. Children load lazily — a workspace can hold thousands
/// of files and the tree should cost nothing until you open a folder.
final class FileNode {
    let url: URL
    let isDir: Bool
    private var loaded = false
    private var kids: [FileNode] = []

    init(url: URL) {
        self.url = url
        self.isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    var name: String { url.lastPathComponent }

    var children: [FileNode] {
        guard isDir else { return [] }
        if !loaded {
            loaded = true
            let items = (try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])) ?? []
            kids = items
                .map(FileNode.init)
                .sorted {
                    if $0.isDir != $1.isDir { return $0.isDir }        // folders first
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
        }
        return kids
    }

    /// Drop caches so a refresh picks up what an agent just wrote.
    func invalidate() { loaded = false; kids = [] }
}

final class FileTreeView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    var onOpen: ((URL) -> Void)?
    /// Last move, so cmd-z can put it back. One level is enough: the undo that
    /// matters is the one immediately after the drag you did not mean.
    private var lastMove: (from: URL, to: URL)?
    private let outline = NSOutlineView()
    private var root: FileNode?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let col = NSTableColumn(identifier: .init("f"))
        col.resizingMask = .autoresizingMask
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.rowSizeStyle = .small
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(clicked)
        outline.backgroundColor = .clear
        // Finder-style rearranging. Registering for file URLs means drags from
        // Finder work too, not only drags inside the tree.
        outline.registerForDraggedTypes([.fileURL])
        outline.setDraggingSourceOperationMask([.move], forLocal: true)
        outline.setDraggingSourceOperationMask([], forLocal: false)

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    /// NSResponder.init() is inherited and does NOT route through init(frame:),
    /// so a bare FileTreeView() would skip all setup and render an empty pane.
    convenience init() { self.init(frame: .zero) }

    func setRoot(_ path: String) {
        root = FileNode(url: URL(fileURLWithPath: path))
        outline.reloadData()
    }

    func refresh() {
        root?.invalidate()
        outline.reloadData()
    }

    @objc private func clicked() {
        guard let n = outline.item(atRow: outline.clickedRow) as? FileNode else { return }
        if n.isDir {
            outline.isItemExpanded(n) ? outline.collapseItem(n) : outline.expandItem(n)
        } else {
            onOpen?(n.url)
        }
    }

    func outlineView(_ v: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? FileNode)?.children.count ?? (root == nil ? 0 : root!.children.count)
    }
    func outlineView(_ v: NSOutlineView, child i: Int, ofItem item: Any?) -> Any {
        ((item as? FileNode) ?? root!).children[i]
    }
    func outlineView(_ v: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.isDir ?? false
    }
    // MARK: - drag and drop

    func outlineView(_ v: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        (item as? FileNode)?.url as NSURL?
    }

    func outlineView(_ v: NSOutlineView, validateDrop info: NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        // Only ever drop INTO a folder. Dropping between rows would imply an
        // ordering the filesystem does not have.
        guard index == NSOutlineViewDropOnItemIndex else { return [] }
        guard let dest = (item as? FileNode) ?? root, dest.isDir else { return [] }
        guard let urls = info.draggingPasteboard.readObjects(
                forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty else { return [] }
        // Refuse a folder onto itself or into its own subtree, which would
        // otherwise silently destroy it.
        for u in urls {
            if u == dest.url { return [] }
            if dest.url.path.hasPrefix(u.path + "/") { return [] }
            if u.deletingLastPathComponent() == dest.url { return [] }   // already there
        }
        return .move
    }

    func outlineView(_ v: NSOutlineView, acceptDrop info: NSDraggingInfo,
                     item: Any?, childIndex index: Int) -> Bool {
        guard let dest = (item as? FileNode) ?? root, dest.isDir,
              let urls = info.draggingPasteboard.readObjects(
                forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty else { return false }

        // Moving files is the one destructive thing this window can do, so it
        // asks — naming what moves and where, rather than a generic "are you
        // sure". Agents are writing in this tree; a silent move is how you lose
        // work you cannot find again.
        let names = urls.map { $0.lastPathComponent }
        let a = NSAlert()
        a.messageText = urls.count == 1
            ? "Move \(names[0]) into \(dest.name)?"
            : "Move \(urls.count) items into \(dest.name)?"
        a.informativeText = (urls.count == 1 ? "" : names.prefix(8).joined(separator: ", ")
                             + (urls.count > 8 ? ", and \(urls.count - 8) more" : "") + "\n\n")
            + "To:  " + (dest.url.path as NSString).abbreviatingWithTildeInPath
            + "\n\nThis moves the files on disk. cmd-z undoes the last move."
        a.addButton(withTitle: "Move"); a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return false }

        var moved = 0
        var failures: [String] = []
        for u in urls {
            let target = dest.url.appendingPathComponent(u.lastPathComponent)
            if FileManager.default.fileExists(atPath: target.path) {
                failures.append("\(u.lastPathComponent): something with that name is already there")
                continue
            }
            do {
                try FileManager.default.moveItem(at: u, to: target)
                lastMove = (from: target, to: u)      // reversed, ready to undo
                moved += 1
            } catch {
                failures.append("\(u.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty {
            let e = NSAlert()
            e.messageText = moved > 0 ? "Moved \(moved), but not all of them" : "Nothing moved"
            e.informativeText = failures.joined(separator: "\n")
            e.runModal()
        }
        refresh()
        return moved > 0
    }

    /// cmd-z. Only the last move, and only if nothing has taken its place.
    @objc func undoLastMove() {
        guard let m = lastMove else { NSSound.beep(); return }
        guard !FileManager.default.fileExists(atPath: m.to.path) else {
            let a = NSAlert()
            a.messageText = "Cannot undo"
            a.informativeText = "Something is already at \(m.to.lastPathComponent)."
            a.runModal(); return
        }
        try? FileManager.default.moveItem(at: m.from, to: m.to)
        lastMove = nil
        refresh()
    }

    func outlineView(_ v: NSOutlineView, viewFor col: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? FileNode else { return nil }
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = v.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? {
            let c = NSTableCellView(); c.identifier = id
            let t = NSTextField(labelWithString: "")
            t.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            t.lineBreakMode = .byTruncatingMiddle
            t.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(t); c.textField = t
            NSLayoutConstraint.activate([
                t.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                t.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -2),
                t.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        cell.textField?.stringValue = (n.isDir ? "▸ " : "   ") + n.name
        cell.textField?.textColor = Theme.ui.text
        return cell
    }

    /// Repaint after a light/dark flip.
    func restyle() { outline.reloadData() }
}
