import AppKit
import ColdfallCore

/// "What this desk has": its MCP servers, skills, plugins and hooks, read from
/// disk (see ColdfallCore/Inventory.swift). Read-only; trimming servers is on
/// the desk's right-click menu.
final class InventoryWindow: NSWindowController {

    convenience init(desk: Desk, inventory: Inventory) {
        let vis = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1280, height: 800)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: min(640, vis.height - 80)),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "What \(desk.name) has"
        w.contentMinSize = NSSize(width: 460, height: 320)
        self.init(window: w)

        let box = NSView(frame: w.contentRect(forFrameRect: w.frame))
        let scroll = NSScrollView(frame: box.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        // The standard wrapping text view: as wide as the scroll view, as
        // tall as its text.
        let size = scroll.contentSize
        let text = NSTextView(frame: NSRect(origin: .zero, size: size))
        text.minSize = NSSize(width: 0, height: size.height)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.containerSize = NSSize(width: size.width, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        text.isEditable = false
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 20, height: 18)
        text.textStorage?.setAttributedString(InventoryWindow.render(desk: desk, inventory: inventory))
        scroll.documentView = text
        box.addSubview(scroll)
        w.contentView = box
        w.center()
    }

    static func render(desk: Desk, inventory inv: Inventory) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: 12.5)
        func add(_ s: String, _ font: NSFont, _ color: NSColor, space: CGFloat = 2) {
            let p = NSMutableParagraphStyle(); p.paragraphSpacing = space
            out.append(NSAttributedString(string: s + "\n", attributes: [.font: font, .foregroundColor: color, .paragraphStyle: p]))
        }
        func section(_ title: String, _ why: String, _ items: [Inventory.Item], empty: String) {
            add("", body, .labelColor, space: 4)
            add(title, .systemFont(ofSize: 10.5, weight: .semibold), .tertiaryLabelColor)
            add(why, .systemFont(ofSize: 11.5), .secondaryLabelColor, space: 8)
            if items.isEmpty { add(empty, body, .tertiaryLabelColor); return }
            for it in items {
                let line = NSMutableAttributedString()
                line.append(NSAttributedString(string: it.name, attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: it.off ? NSColor.tertiaryLabelColor : NSColor.labelColor,
                    .strikethroughStyle: it.off ? NSUnderlineStyle.single.rawValue : 0,
                ]))
                line.append(NSAttributedString(string: "   " + it.source + (it.off ? ", off for this desk" : ""), attributes: [
                    .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor,
                ]))
                if !it.detail.isEmpty {
                    line.append(NSAttributedString(string: "\n" + it.detail, attributes: [
                        .font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: NSColor.secondaryLabelColor,
                    ]))
                }
                let p = NSMutableParagraphStyle(); p.paragraphSpacing = 7
                line.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: p]))
                out.append(line)
            }
        }

        add(desk.name, .systemFont(ofSize: 18, weight: .semibold), .labelColor, space: 2)
        add("\(desk.runtime) · \((desk.resolvedCwd as NSString).abbreviatingWithTildeInPath)",
            .systemFont(ofSize: 11.5), .secondaryLabelColor, space: 4)

        let local = inv.mcp.filter { !$0.off && $0.detail.hasSuffix("on this Mac") }.count
        section("MCP SERVERS",
                "Programs that give the agent tools. Each one that runs on this Mac takes memory while the desk runs"
                + (local > 0 ? " (\(local) here)" : "") + ". To switch some off, right-click the desk and choose MCP Servers…",
                inv.mcp, empty: "None.")
        section("HOOKS",
                "Commands that run by themselves on an event, like every session start or every tool call. "
                + "The one kind that acts without being asked.",
                inv.hooks, empty: "None.")
        section("SKILLS",
                "Instructions the agent reads only when a task calls for them. Nearly free until used.",
                inv.skills, empty: "None.")
        section("PLUGINS",
                "Packages that bring skills, hooks and servers with them. What each carries is listed above under its name.",
                inv.plugins, empty: "None.")
        if !inv.notes.isEmpty {
            add("", body, .labelColor, space: 4)
            for n in inv.notes { add(n, .systemFont(ofSize: 11.5), .secondaryLabelColor, space: 4) }
        }
        return out
    }
}
