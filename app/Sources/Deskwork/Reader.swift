import AppKit
import PDFKit
import QuickLookUI

/// Read-only viewer. Deskwork is run-first: agents write, you read. That is what
/// lets this be a few hundred lines instead of an editor, and it is why PDFs are
/// trivial here when Zed still cannot open one.
final class ReaderView: NSView {
    private let titleBar = NSTextField(labelWithString: "")
    private let container = NSView()
    private var current: NSView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor

        titleBar.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        titleBar.textColor = .secondaryLabelColor
        titleBar.lineBreakMode = .byTruncatingHead
        titleBar.translatesAutoresizingMaskIntoConstraints = false
        container.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleBar); addSubview(container)
        NSLayoutConstraint.activate([
            titleBar.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            titleBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            titleBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            container.topAnchor.constraint(equalTo: titleBar.bottomAnchor, constant: 6),
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        showPlaceholder()
    }
    required init?(coder: NSCoder) { fatalError() }
    /// NSResponder.init() is inherited and does NOT route through init(frame:),
    /// so a bare ReaderView() would skip all setup and render an empty pane.
    convenience init() { self.init(frame: .zero) }

    private func swap(to v: NSView) {
        current?.removeFromSuperview()
        v.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: container.topAnchor),
            v.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        current = v
    }

    private func showPlaceholder() {
        let l = NSTextField(labelWithString: "Pick a file in the tree.")
        l.textColor = .tertiaryLabelColor
        l.alignment = .center
        swap(to: l)
    }

    func open(_ url: URL) {
        titleBar.stringValue = url.path
            .replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")

        let ext = url.pathExtension.lowercased()

        if ext == "pdf", let doc = PDFDocument(url: url) {
            let v = PDFView()
            v.document = doc
            v.autoScales = true
            v.displayMode = .singlePageContinuous
            swap(to: v)
            return
        }

        if ["png","jpg","jpeg","gif","heic","webp","tiff","bmp","svg"].contains(ext),
           let img = NSImage(contentsOf: url) {
            let v = NSImageView()
            v.image = img
            v.imageScaling = .scaleProportionallyUpOrDown
            swap(to: v)
            return
        }

        // Anything else: show it as text if it is text, refuse politely if not.
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return showMessage("Could not read that file.")
        }
        let head = data.prefix(8000)
        if head.contains(0) { return showMessage("Binary file — nothing to show.") }
        guard let text = String(data: data.prefix(2_000_000), encoding: .utf8)
                      ?? String(data: data.prefix(2_000_000), encoding: .isoLatin1) else {
            return showMessage("Could not decode that file as text.")
        }

        let tv = NSTextView()
        tv.isEditable = false
        tv.isRichText = false
        tv.drawsBackground = false
        tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.textContainerInset = NSSize(width: 10, height: 8)
        tv.string = text
        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        tv.autoresizingMask = [.width]
        tv.isVerticallyResizable = true
        tv.textContainer?.widthTracksTextView = true
        swap(to: scroll)
    }

    private func showMessage(_ s: String) {
        let l = NSTextField(labelWithString: s)
        l.textColor = .tertiaryLabelColor
        l.alignment = .center
        swap(to: l)
    }
}
