import AppKit
import DeskworkCore
import PDFKit

/// Read-only viewer with tabs.
///
/// Two ways a file lands here. You click it in the tree, or an agent writes it
/// and the workspace watcher opens it for you — which is the behaviour worth
/// having: you do not know which file the agent is about to touch, so you
/// cannot have opened it first.
///
/// Agent-opened tabs are marked as transient (italic, like a preview tab) and
/// the oldest is recycled, so a busy agent does not bury you in tabs. Clicking
/// one, or editing what it shows, makes it permanent.
final class ReaderView: NSView {
    private let tabBar = NSStackView()
    private let tabScroll = NSScrollView()
    private let container = NSView()
    private let titleBar = NSTextField(labelWithString: "")

    private struct Tab {
        let url: URL
        var view: NSView
        var transient: Bool
        var watcher: DispatchSourceFileSystemObject?
    }
    private var tabs: [Tab] = []
    private var activeIndex: Int? = nil
    private let maxTransient = 4

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor

        tabBar.orientation = .horizontal
        tabBar.spacing = 1
        tabBar.alignment = .centerY
        tabBar.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        tabScroll.documentView = tabBar
        tabScroll.hasHorizontalScroller = false
        tabScroll.drawsBackground = false
        tabScroll.translatesAutoresizingMaskIntoConstraints = false

        titleBar.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        titleBar.textColor = .tertiaryLabelColor
        titleBar.lineBreakMode = .byTruncatingHead
        titleBar.translatesAutoresizingMaskIntoConstraints = false
        container.translatesAutoresizingMaskIntoConstraints = false

        addSubview(tabScroll); addSubview(titleBar); addSubview(container)
        NSLayoutConstraint.activate([
            tabScroll.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            tabScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            tabScroll.heightAnchor.constraint(equalToConstant: 26),
            titleBar.topAnchor.constraint(equalTo: tabScroll.bottomAnchor, constant: 2),
            titleBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            titleBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            container.topAnchor.constraint(equalTo: titleBar.bottomAnchor, constant: 4),
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        showPlaceholder()
    }
    required init?(coder: NSCoder) { fatalError() }
    convenience init() { self.init(frame: .zero) }

    // MARK: - opening

    /// Clicked in the tree: a permanent tab.
    func open(_ url: URL) { openTab(url, transient: false) }

    /// Written by an agent: a transient tab, recycled once there are too many.
    func openFromAgent(_ url: URL) { openTab(url, transient: true) }

    private func openTab(_ url: URL, transient: Bool) {
        if let i = tabs.firstIndex(where: { $0.url == url }) {
            if !transient { tabs[i].transient = false }   // clicking pins it
            select(i)
            return
        }
        guard let v = buildView(for: url) else { return }

        if transient {
            // Keep the flood bounded: recycle the oldest transient tab.
            let transients = tabs.enumerated().filter { $0.element.transient }
            if transients.count >= maxTransient, let oldest = transients.first {
                close(at: oldest.offset, rebuild: false)
            }
        }
        var t = Tab(url: url, view: v, transient: transient, watcher: nil)
        t.watcher = watch(url)
        tabs.append(t)
        select(tabs.count - 1)
    }

    private func select(_ i: Int) {
        guard tabs.indices.contains(i) else { return }
        activeIndex = i
        container.subviews.forEach { $0.removeFromSuperview() }
        let v = tabs[i].view
        v.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: container.topAnchor),
            v.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        titleBar.stringValue = (tabs[i].url.path as NSString).abbreviatingWithTildeInPath
        rebuildTabs()
    }

    private func close(at i: Int, rebuild: Bool = true) {
        guard tabs.indices.contains(i) else { return }
        tabs[i].watcher?.cancel()
        tabs.remove(at: i)
        if tabs.isEmpty { activeIndex = nil; showPlaceholder(); if rebuild { rebuildTabs() }; return }
        select(min(i, tabs.count - 1))
    }

    @objc private func tabClicked(_ s: NSButton) { select(s.tag) }
    @objc private func tabClosed(_ s: NSButton) { close(at: s.tag) }

    private func rebuildTabs() {
        tabBar.arrangedSubviews.forEach { tabBar.removeArrangedSubview($0); $0.removeFromSuperview() }
        for (i, t) in tabs.enumerated() {
            let on = i == activeIndex
            let b = NSButton(title: t.url.lastPathComponent, target: self, action: #selector(tabClicked(_:)))
            b.tag = i
            b.bezelStyle = .inline
            b.isBordered = false
            // Transient tabs read as italic, the way a preview tab does.
            let size: CGFloat = 11.5
            b.font = t.transient
                ? NSFontManager.shared.convert(.systemFont(ofSize: size), toHaveTrait: .italicFontMask)
                : .systemFont(ofSize: size, weight: on ? .semibold : .regular)
            b.contentTintColor = on ? .controlAccentColor : .secondaryLabelColor
            b.toolTip = t.url.path
            let x = NSButton(title: "×", target: self, action: #selector(tabClosed(_:)))
            x.tag = i; x.bezelStyle = .inline; x.isBordered = false
            x.font = .systemFont(ofSize: 11)
            x.contentTintColor = .tertiaryLabelColor
            let cell = NSStackView(views: [b, x])
            cell.orientation = .horizontal; cell.spacing = 0
            tabBar.addArrangedSubview(cell)
        }
        tabBar.layoutSubtreeIfNeeded()
        tabBar.frame = NSRect(x: 0, y: 0,
                              width: max(tabBar.fittingSize.width, tabScroll.bounds.width),
                              height: 26)
    }

    // MARK: - content

    private func swapPlaceholder(_ v: NSView) {
        container.subviews.forEach { $0.removeFromSuperview() }
        v.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(v)
        NSLayoutConstraint.activate([
            v.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            v.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
    }

    private func showPlaceholder() {
        let l = NSTextField(labelWithString: "Pick a file, or let a desk open one.")
        l.textColor = .tertiaryLabelColor
        swapPlaceholder(l)
        titleBar.stringValue = ""
    }

    private func message(_ s: String) -> NSView {
        let l = NSTextField(labelWithString: s)
        l.textColor = .tertiaryLabelColor
        l.alignment = .center
        return l
    }

    private func buildView(for url: URL) -> NSView? {
        let ext = url.pathExtension.lowercased()

        if ext == "pdf", let doc = PDFDocument(url: url) {
            let v = PDFView(); v.document = doc; v.autoScales = true
            v.displayMode = .singlePageContinuous
            return v
        }
        if ["png","jpg","jpeg","gif","heic","webp","tiff","bmp","svg"].contains(ext),
           let img = NSImage(contentsOf: url) {
            let v = NSImageView(); v.image = img
            v.imageScaling = .scaleProportionallyUpOrDown
            return v
        }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return message("Could not read that file.")
        }
        if data.prefix(8000).contains(0) { return message("Binary file — nothing to show.") }
        guard let text = String(data: data.prefix(2_000_000), encoding: .utf8)
                      ?? String(data: data.prefix(2_000_000), encoding: .isoLatin1) else {
            return message("Could not decode that file as text.")
        }

        let tv = NSTextView()
        tv.isEditable = false
        tv.drawsBackground = false
        let f = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.font = f
        tv.textContainerInset = NSSize(width: 10, height: 8)
        if let hl = Highlight.attributed(text, ext: ext, font: f) {
            tv.isRichText = true
            tv.textStorage?.setAttributedString(hl)
        } else {
            tv.isRichText = false
            tv.string = text
        }
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        return scroll
    }

    /// Agents rewrite files while you are reading them, so each tab watches its
    /// own file and refreshes in place, keeping scroll position.
    private func watch(_ url: URL) -> DispatchSourceFileSystemObject? {
        let fd = Darwin.open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self?.refresh(url) }
        }
        src.setCancelHandler { Darwin.close(fd) }
        src.resume()
        return src
    }

    private func refresh(_ url: URL) {
        guard let i = tabs.firstIndex(where: { $0.url == url }),
              let fresh = buildView(for: url) else { return }
        let offset = (tabs[i].view as? NSScrollView)?.contentView.bounds.origin
        tabs[i].view = fresh
        // Replacing by path rather than trusting the descriptor: agents replace
        // files at least as often as they write in place.
        tabs[i].watcher?.cancel()
        tabs[i].watcher = watch(url)
        if activeIndex == i {
            select(i)
            if let o = offset, let sv = tabs[i].view as? NSScrollView {
                sv.contentView.scroll(to: o); sv.reflectScrolledClipView(sv.contentView)
            }
        }
    }
}
