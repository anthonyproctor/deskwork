// Carrying a user's state across the rename from Deskwork to Project Coldfall.
//
// The app used to keep everything under ~/.config/deskwork and
// ~/.local/share/deskwork. It now uses .../coldfall. Somebody upgrading should
// lose nothing and notice nothing — not their desks, not their mailbox, not
// their usage history.
//
// The obvious move is to rename the directories. That is exactly the wrong
// move, and not for a theoretical reason. On the author's own machine,
// ~/.claude/settings.json pointed Claude Code's statusline at
// ~/.config/deskwork/statusline-recorder.sh, and that recorder wrote into
// ~/.local/share/deskwork/limits. A plain rename would have broken the
// statusline in EVERY Claude Code session on the machine, not just inside this
// app — and silently, since a missing statusline command just prints nothing.
//
// So each old directory is moved to its new home and a SYMLINK is left at the
// old path. Every reference anybody already has keeps resolving, including
// ones in files this app has no business editing. Nothing outside the app
// needs to change, ever, and undoing it is two `rm`s and two `mv`s.

import Foundation

public enum Migration {

    public enum Outcome: Equatable {
        /// There was no old directory. A fresh install, or already cleaned up.
        case nothing
        /// The old path is already a symlink. Migrated on an earlier launch.
        case alreadyDone
        /// Moved, and a symlink left behind at the old path.
        case migrated
        /// Both an old directory AND a new one exist as real directories.
        ///
        /// This happens if someone ran the new build, then the old one, and
        /// each wrote its own state. Neither side is obviously right, so
        /// nothing is touched and the user is told. Picking one silently would
        /// mean destroying the other.
        case conflict
        /// The move or the link failed. The message says which, and where.
        case failed(String)
    }

    /// Move `old` to `new` and leave a symlink at `old` pointing at `new`.
    ///
    /// Safe to call on every launch: the second call sees a symlink and does
    /// nothing. Never deletes anything.
    public static func migrate(from old: String, to new: String) -> Outcome {
        let fm = FileManager.default

        // Symlink first: fileExists follows links, so a dangling or live link
        // has to be recognised before anything asks "does this exist".
        if (try? fm.destinationOfSymbolicLink(atPath: old)) != nil {
            return .alreadyDone
        }

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: old, isDirectory: &isDir), isDir.boolValue else {
            return .nothing
        }

        if fm.fileExists(atPath: new) {
            return .conflict
        }

        do {
            try fm.createDirectory(atPath: (new as NSString).deletingLastPathComponent,
                                   withIntermediateDirectories: true)
            try fm.moveItem(atPath: old, toPath: new)
        } catch {
            return .failed("could not move \(old) to \(new): \(error.localizedDescription)")
        }

        do {
            try fm.createSymbolicLink(atPath: old, withDestinationPath: new)
        } catch {
            // The data is safe at its new home; only the compatibility link is
            // missing. That is worth reporting, not worth undoing the move.
            return .failed("moved to \(new), but could not leave a link at \(old): "
                           + error.localizedDescription)
        }
        return .migrated
    }

    /// The directories that moved in the rename, old then new.
    public static var pairs: [(old: String, new: String)] {
        let h = NSHomeDirectory()
        return [
            ("\(h)/.config/deskwork",      "\(h)/.config/coldfall"),
            ("\(h)/.local/share/deskwork", "\(h)/.local/share/coldfall"),
        ]
    }

    /// Run every migration. Call before anything reads config.
    @discardableResult
    public static func runAll() -> [(path: String, outcome: Outcome)] {
        pairs.map { ($0.old, migrate(from: $0.old, to: $0.new)) }
    }
}
