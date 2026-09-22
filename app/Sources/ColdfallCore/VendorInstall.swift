// How to install each vendor's CLI, for someone who has none of them.
//
// A first run with nothing installed used to say "install something, then
// reopen", which is a dead end for exactly the person trying the app for the
// first time. Each line here is a command that was checked to exist (the npm
// packages and the Claude installer URL), plus what the vendor needs from you,
// since every one of them wants an account or a plan before it does anything.
//
// Grok is left out: there is no single official CLI to point at.

import Foundation

public struct VendorInstall: Equatable {
    /// The runtime name, as in desks.toml and Bridge.known.
    public let runtime: String
    public let title: String
    /// Paste this into a terminal.
    public let command: String
    /// Another way, when the first needs something you may not have.
    public let alternative: String?
    /// What the vendor needs before it works.
    public let needs: String
    public let docs: String

    public static let all: [VendorInstall] = [
        VendorInstall(runtime: "claude", title: "Claude Code",
                      command: "curl -fsSL https://claude.ai/install.sh | bash",
                      alternative: "npm install -g @anthropic-ai/claude-code",
                      needs: "A Claude Pro or Max plan, or an Anthropic API account. Run claude once to sign in.",
                      docs: "https://code.claude.com/docs"),
        VendorInstall(runtime: "codex", title: "Codex",
                      command: "npm install -g @openai/codex",
                      alternative: "brew install --cask codex",
                      needs: "A ChatGPT plan or an OpenAI API key. Run codex once to sign in.",
                      docs: "https://github.com/openai/codex"),
        VendorInstall(runtime: "antigravity", title: "Antigravity CLI",
                      command: "curl -fsSL https://antigravity.google/cli/install.sh | bash",
                      alternative: nil,
                      needs: "A Google account; Google AI Pro and Ultra plans use this. Run agy once to sign in.",
                      docs: "https://antigravity.google/docs/cli/install"),
        VendorInstall(runtime: "copilot", title: "GitHub Copilot CLI",
                      command: "npm install -g @github/copilot",
                      alternative: nil,
                      needs: "A GitHub Copilot plan. Run copilot once to sign in.",
                      docs: "https://github.com/github/copilot-cli"),
        VendorInstall(runtime: "ollama", title: "Ollama",
                      command: "brew install ollama",
                      alternative: "or download the app from ollama.com",
                      needs: "Nothing: models run on this Mac, free. Pull one with ollama pull llama3.",
                      docs: "https://ollama.com"),
    ]

    /// The install line for runtime, if there is one to give.
    public static func of(_ runtime: String) -> VendorInstall? { all.first { $0.runtime == runtime } }

    /// Why an npm line may fail: npm comes with Node.js, which many Macs lack.
    public static let npmNote = "Lines starting with npm need Node.js (nodejs.org). "
        + "Lines starting with brew need Homebrew (brew.sh)."
}
