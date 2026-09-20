// Knowing a desk answered while you were looking somewhere else.
//
// The point of desks is running several agents at once, which means you are
// never watching more than one of them. Without a signal you find out an agent
// answered by remembering to go and look — which is the failure the whole
// arrangement exists to remove.
//
// The hard part is that no CLI announces "I have finished answering". All that
// reaches Deskwork is bytes on a pty, so "finished" has to be inferred from
// bytes STOPPING. That inference has two failure modes and they pull in
// opposite directions:
//
//   * Too short a quiet window and an agent that pauses mid-answer is reported
//     as done, so the badge flickers during a single reply and stops meaning
//     anything.
//   * Too long and the badge lags far enough behind the work to be useless.
//
// Two seconds is the compromise. It lives here, in the Foundation-only core,
// because it is pure logic with a real failure mode and belongs under test
// rather than buried in a view.

import Foundation

/// What a desk is doing, for the badge in the rail.
public enum DeskActivity: Equatable {
    /// Nothing to report: idle, or you are looking at it right now.
    case quiet
    /// Output is arriving. The agent is mid-thought.
    case working
    /// Output arrived and then stopped while you were elsewhere. This is the
    /// state worth a badge: an answer is sitting there waiting.
    case ready
}

/// The state machine behind one desk's badge.
public struct ActivityState {

    /// How long output must stop for before a desk counts as finished.
    public static let quietFor: TimeInterval = 2.0

    public private(set) var lastOutput: Date?
    /// Output arrived while the desk was not on screen.
    public private(set) var unseen = false
    /// Looking at a desk is the ONLY thing that clears it. Not hovering, not
    /// the app coming forward — a badge that clears itself is worse than none,
    /// because you stop trusting that it was ever set.
    public private(set) var visible = false

    public init() {}

    public mutating func noteOutput(at now: Date = Date()) {
        lastOutput = now
        if !visible { unseen = true }
    }

    public mutating func setVisible(_ v: Bool) {
        visible = v
        if v { unseen = false }
    }

    public func activity(now: Date = Date()) -> DeskActivity {
        // A desk you are looking at never badges: you can see it.
        guard !visible, let last = lastOutput else { return .quiet }
        if now.timeIntervalSince(last) < ActivityState.quietFor { return .working }
        return unseen ? .ready : .quiet
    }
}
