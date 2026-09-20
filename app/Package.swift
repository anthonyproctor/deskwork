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
        .executable(name: "deskwork-test", targets: ["DeskworkTests"]),
    ],
    dependencies: [
        // Pinned, not tracking main. CI failed on its first run because main had
        // moved to a Swift tools version newer than the runner's — a build that
        // breaks with no change on our side is not a dependency, it is a
        // liability.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.5.0")
    ],
    targets: [
        // No platform UI dependency of any kind.
        .target(name: "DeskworkCore"),
        // The macOS front end.
        .executableTarget(name: "Deskwork", dependencies: ["DeskworkCore", "SwiftTerm"]),
        // Proves the core is genuinely headless, and gives a front end in any
        // language something to shell out to.
        .executableTarget(name: "DeskworkCLI", dependencies: ["DeskworkCore"]),
        // Plain executable, not XCTest. XCTest ships with Xcode, and the whole
        // point of this project building on Command Line Tools alone is that a
        // contributor needs no 15GB download — tests that break that promise
        // are worse than tests that are slightly less ergonomic.
        .executableTarget(name: "DeskworkTests", dependencies: ["DeskworkCore"]),
    ]
)
