// swift-tools-version:5.9
import PackageDescription

// Two targets on purpose. DeskworkCore must not import AppKit — that boundary
// is what keeps a future Linux or Windows front end a UI project rather than a
// rewrite. Roughly a third of the code lives below the line and is already
// nothing but file reads and CLI invocations.
let package = Package(
    name: "Deskwork",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "DeskworkCore", targets: ["DeskworkCore"]),
        .executable(name: "Deskwork", targets: ["Deskwork"]),
        .executable(name: "deskwork-cli", targets: ["DeskworkCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", branch: "main")
    ],
    targets: [
        // No platform UI dependency of any kind.
        .target(name: "DeskworkCore"),
        // The macOS front end.
        .executableTarget(name: "Deskwork", dependencies: ["DeskworkCore", "SwiftTerm"]),
        // Proves the core is genuinely headless, and gives a front end in any
        // language something to shell out to.
        .executableTarget(name: "DeskworkCLI", dependencies: ["DeskworkCore"]),
    ]
)
