import AppKit

struct BridgeError: Error { let message: String }

/// Cross-vendor handoff — a MAILBOX, not a protocol.
///
/// Two agents from different companies pass work back and forth through an
/// append-only markdown thread. A wire protocol is the obvious design and the
/// wrong one here:
///
///   * Vendor-agnostic. Anything with a headless mode can join. No adapter, no
///     SDK, no version coupling to anybody's release train.
///   * The thread IS the context. Each headless invocation starts with no
///     memory, so the file carries the conversation. This is why it APPENDS:
///     replacing the thread once destroyed a long exchange by overwriting it
///     with an answer from a session that had never read it.
///   * Inspectable. The exchange is a file you can read, diff, and keep.
///   * The responder is READ-ONLY, enforced by the vendor's own flag, so a
///     second opinion can never quietly edit your workspace.
///
/// Credit where due: this pattern comes from a working hand-rolled setup
/// (`ask-claude.sh` driving a pair of markdown files). Deskwork generalises it
/// to arbitrary runtime pairs and ships it built in, so a new user needs
/// nothing but the CLIs they already have.
enum Bridge {

    struct Runtime {
        let name: String
        let bin: String
        /// argv for a headless, read-only answer.
        let argv: (String) -> [String]
        /// Whether read-only is actually ENFORCED by a vendor flag, or merely
        /// requested in the prompt. Shown in the UI; never overstated.
        let readOnlyEnforced: Bool
    }

    static let known: [Runtime] = [
        Runtime(name: "claude", bin: "claude",
                argv: { ["-p", $0, "--permission-mode", "plan"] }, readOnlyEnforced: true),
        Runtime(name: "codex", bin: "codex",
                argv: { ["exec", "--sandbox", "read-only", $0] }, readOnlyEnforced: true),
        Runtime(name: "gemini", bin: "gemini",
                argv: { ["-p", $0] }, readOnlyEnforced: false),
        Runtime(name: "copilot", bin: "copilot",
                argv: { ["-p", $0] }, readOnlyEnforced: false),
    ]

    static func available() -> [Runtime] { known.filter { DeskConfig.which($0.bin) != nil } }
    static func runtime(named n: String) -> Runtime? { known.first { $0.name == n } }

    /// Wraps the thread so the responder knows it is reviewing, not driving.
    static func framePrompt(thread: String, ask: String, enforced: Bool) -> String {
        var p = """
        You are taking part in an agent-to-agent review. Another AI agent is asking you \
        to look at something in this workspace and answer.

        Be precise. Challenge claims that are not supported. Cite file paths and line \
        numbers. If you disagree with the other agent, say so plainly and say why.
        """
        if !enforced {
            p += "\n\nDo not edit, delete, commit, push, or make any external change. Answer only."
        }
        if !thread.isEmpty {
            p += "\n\nTHREAD SO FAR (oldest first):\n\n\(thread)"
        }
        p += "\n\nLATEST MESSAGE, answer this:\n\n\(ask)"
        return p
    }
}

/// One append-only thread between two runtimes.
struct Mailbox {
    var dir: String
    /// Optional: an existing runner script (a user who already built one).
    var runner: String?
    var legacyOutbound: String?
    var legacyInbound: String?

    static let configPath = NSString(string: "~/.config/deskwork/bridge.toml").expandingTildeInPath
    static let defaultDir = NSString(string: "~/.local/share/deskwork/mail").expandingTildeInPath

    /// Always returns a usable mailbox. No config means the built-in one.
    static func load() -> Mailbox {
        guard let text = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            return Mailbox(dir: defaultDir)
        }
        var kv: [String: String] = [:]
        for raw in text.split(separator: "\n") {
            var line = String(raw)
            if let h = line.firstIndex(of: "#") { line = String(line[line.startIndex..<h]) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            kv[String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces)] =
                String(line[line.index(after: eq)...])
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return Mailbox(dir: NSString(string: kv["dir"] ?? defaultDir).expandingTildeInPath,
                       runner: kv["runner"],
                       legacyOutbound: kv["outbound"],
                       legacyInbound: kv["inbound"])
    }

    var usesLegacyRunner: Bool { runner != nil && legacyOutbound != nil }

    func threadPath(_ a: String, _ b: String) -> String {
        if let o = legacyInbound { return (dir as NSString).appendingPathComponent(o) }
        let pair = [a, b].sorted().joined(separator: "-")
        return (dir as NSString).appendingPathComponent("thread-\(pair).md")
    }

    func read(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }

    /// Append, never replace.
    func append(_ text: String, who: String, to path: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm zzz"
        let block = "\n\n---\n\n## \(who) · \(f.string(from: Date()))\n\n\(text)\n"
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile(); fh.write(block.data(using: .utf8)!); fh.closeFile()
        } else {
            try? block.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// Ask `to` to answer, with the whole thread as context. Appends the reply.
    func ask(from: String, to rt: Bridge.Runtime, message: String, cwd: String,
             completion: @escaping (Result<String, BridgeError>) -> Void) {
        let path = threadPath(from, rt.name)
        append(message, who: from, to: path)
        let thread = read(path)
        let prompt = Bridge.framePrompt(thread: thread, ask: message, enforced: rt.readOnlyEnforced)

        guard let bin = DeskConfig.which(rt.bin) else {
            completion(.failure(BridgeError(message: "\(rt.bin) is not on PATH"))); return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = rt.argv(prompt)
            p.currentDirectoryURL = URL(fileURLWithPath: cwd)
            // A nested agent session refuses to start; clear the marker.
            var env = ProcessInfo.processInfo.environment
            env["CLAUDECODE"] = ""; env["CLAUDE_CODE_ENTRYPOINT"] = ""
            p.environment = env
            let out = Pipe(), err = Pipe()
            p.standardOutput = out; p.standardError = err
            p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch {
                DispatchQueue.main.async { completion(.failure(BridgeError(message: "could not start \(rt.bin): \(error)"))) }
                return
            }
            let d = out.fileHandleForReading.readDataToEndOfFile()
            let e = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            var reply = String(data: d, encoding: .utf8) ?? ""
            if reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                reply = String(data: e, encoding: .utf8) ?? "(no output)"
            }
            append(reply, who: rt.name, to: path)
            DispatchQueue.main.async { completion(.success(reply)) }
        }
    }

    /// Hand off to a user's own runner script instead.
    func runRunner(completion: @escaping (String) -> Void) {
        guard let runner else { completion("no runner configured"); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", runner]
            p.currentDirectoryURL = URL(fileURLWithPath: dir)
            var env = ProcessInfo.processInfo.environment
            env["CLAUDECODE"] = ""; env["CLAUDE_CODE_ENTRYPOINT"] = ""
            p.environment = env
            let out = Pipe(); p.standardOutput = out; p.standardError = out
            p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch { DispatchQueue.main.async { completion("\(error)") }; return }
            let d = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            DispatchQueue.main.async { completion(String(data: d, encoding: .utf8) ?? "") }
        }
    }
}
