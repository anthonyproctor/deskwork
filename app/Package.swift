// swift-tools-version:5.9
import PackageDescription

// Two targets on purpose. ColdfallCore must not import AppKit — that boundary
// is what keeps a future Linux or Windows front end a UI project rather than a
// rewrite. Roughly a third of the code lives below the line and is already
// nothing but file reads and CLI invocations.
let package = Package(
    name: "ProjectColdfall",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ColdfallCore", targets: ["ColdfallCore"]),
        .executable(name: "Coldfall", targets: ["Coldfall"]),
        .executable(name: "coldfall-cli", targets: ["ColdfallCLI"]),
        .executable(name: "coldfall-test", targets: ["ColdfallTests"]),
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
        .target(name: "ColdfallCore"),
        // The macOS front end.
        .executableTarget(name: "Coldfall", dependencies: ["ColdfallCore", "SwiftTerm"]),
        // Proves the core is genuinely headless, and gives a front end in any
        // language something to shell out to.
        .executableTarget(name: "ColdfallCLI", dependencies: ["ColdfallCore"]),
        // Plain executable, not XCTest. XCTest ships with Xcode, and the whole
        // point of this project building on Command Line Tools alone is that a
        // contributor needs no 15GB download — tests that break that promise
        // are worse than tests that are slightly less ergonomic.
        .executableTarget(name: "ColdfallTests", dependencies: ["ColdfallCore"]),
    ]
)
