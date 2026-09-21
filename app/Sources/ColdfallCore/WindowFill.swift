// Double-clicking the title strip fills the screen, and double-clicking again
// puts the window back.
//
// This used NSWindow.zoom, which decides "zoom in or back out" by whether the
// frame still matches the one it zoomed to. A double-click is two clicks, and
// the first starts a window drag; that nudge was enough for zoom to think the
// window had been moved, so the second double-click zoomed again instead of
// restoring. The decision lives here, on frames alone.

import Foundation

/// A window or screen rectangle, in the same coordinates AppKit uses. Kept
/// here rather than CGRect so the core stays Foundation-only.
public struct Frame: Equatable {
    public var x, y, w, h: Double
    public init(x: Double, y: Double, w: Double, h: Double) { self.x = x; self.y = y; self.w = w; self.h = h }
}

public enum WindowFill {

    /// Near enough to count as filling the screen: a point or two of drift
    /// from a drag, or a titlebar's rounding, must not change the answer.
    public static func fills(_ f: Frame, _ v: Frame, slack: Double = 12) -> Bool {
        abs(f.x - v.x) <= slack && abs(f.y - v.y) <= slack && abs(f.w - v.w) <= slack && abs(f.h - v.h) <= slack
    }

    /// Where a double-click takes the window, and the frame to remember.
    ///
    /// Filling: back to the remembered frame (or a sensible middle size if
    /// there is none). Not filling: remember this frame, fill the screen.
    public static func toggle(frame: Frame, visible: Frame, saved: Frame?) -> (next: Frame, saved: Frame?) {
        if fills(frame, visible) {
            let middle = Frame(x: visible.x + visible.w * 0.12, y: visible.y + visible.h * 0.1,
                               w: visible.w * 0.76, h: visible.h * 0.8)
            return (saved.flatMap { fills($0, visible) ? nil : $0 } ?? middle, nil)
        }
        return (visible, frame)
    }
}
