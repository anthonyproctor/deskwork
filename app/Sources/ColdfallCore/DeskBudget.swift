// A weekly budget for a desk.
//
// Paperclip (paperclip.ing) caps each agent at a monthly budget and pauses it
// at the limit. Pausing is the wrong half to borrow here: Coldfall never runs
// an agent on its own, and stopping one mid-task loses work. The useful half
// is knowing, at a glance, which desk is eating the week. So a desk can carry
// `budget = 50` (dollars a week), and the rail says when it's close or over.
//
// Dollars, so Claude desks only: Coldfall prices Claude from the official
// table (see Pricing) and guesses no other vendor's prices.

import Foundation

public enum DeskBudget {

    public enum Status: Equatable {
        /// No budget set.
        case unset
        case ok(spent: Double, budget: Double)
        /// 80% or more of the week's budget.
        case near(spent: Double, budget: Double)
        case over(spent: Double, budget: Double)
    }

    public static let nearAt = 0.8

    public static func status(spent: Double?, budget: Double?) -> Status {
        guard let b = budget, b > 0 else { return .unset }
        let s = spent ?? 0
        if s >= b { return .over(spent: s, budget: b) }
        if s >= b * nearAt { return .near(spent: s, budget: b) }
        return .ok(spent: s, budget: b)
    }

    /// "$46 of $50 this week".
    public static func label(_ s: Status) -> String? {
        switch s {
        case .unset: return nil
        case .ok(let spent, let b), .near(let spent, let b), .over(let spent, let b):
            return String(format: "$%.0f of $%.0f this week", spent, b)
        }
    }

    /// The rail's short form, "$46/$50", only once it's worth a word.
    public static func short(_ s: Status) -> String? {
        switch s {
        case .near(let spent, let b), .over(let spent, let b):
            return String(format: "$%.0f/$%.0f", spent, b)
        default: return nil
        }
    }

    /// What a desk has spent this week, from a usage report. Claude records
    /// spend under the conversation's title, which is the desk's name unless
    /// the desk says otherwise (`conversation`).
    public static func spent(by desk: Desk, in report: Usage.Report) -> Double? {
        report.byDesk[desk.conversation ?? desk.name]?.usd
    }
}
