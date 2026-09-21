// The strip across the top of the main window.
//
// The window uses a full-size content view with a transparent titlebar, for
// the unified look VS Code and Cursor have. But the content was pinned to the
// very top of the window, so the file tree ran up UNDER the traffic lights:
// the window's own title text was drawn straight over "EXPLORER", and a
// double-click at the top landed on the tree instead of the titlebar, so it
// never zoomed.
//
// This strip claims that space. The traffic lights sit in it, the desk name is
// centred in it, everything else starts below it, and a double-click toggles
// the window between its size and the whole screen — dock and menu bar still
// visible. That is zoom, deliberately not the green button's full screen,
// which hides the dock and moves the window to its own space.

import AppKit

final class TitleStrip: NSView {

    let label = NSTextField(labelWithString: "")

    /// Dragging the strip moves the window, as a titlebar should.
    override var mouseDownCanMoveWindow: Bool { true }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            // Stay clear of the traffic lights on the left.
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 80),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -80),
        ])
        restyle()
    }
    required init?(coder: NSCoder) { nil }

    func restyle() {
        layer?.backgroundColor = Theme.ui.sidebar.cgColor
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = Theme.ui.dimText
    }

    override func mouseDown(with e: NSEvent) {
        if e.clickCount == 2 {
            // zoom toggles between the user's size and the screen's visible
            // frame, which excludes the dock and menu bar. A second
            // double-click restores the previous size.
            window?.zoom(nil)
        } else {
            window?.performDrag(with: e)
        }
    }
}
