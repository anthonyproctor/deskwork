import AppKit

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
    func outlineView(_ v: NSOutlineView, viewFor col: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? FileNode else { return nil }
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = v.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? {
            let c = NSTableCellView(); c.identifier = id
            let t = NSTextField(labelWithString: "")
            t.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
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
        cell.textField?.stringValue = (n.isDir ? "▸ " : "  ") + n.name
        cell.textField?.textColor = n.isDir ? .labelColor : .secondaryLabelColor
        return cell
    }
}
