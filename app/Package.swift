// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Deskwork",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", branch: "main")
    ],
    targets: [
        .executableTarget(name: "Deskwork", dependencies: ["SwiftTerm"])
    ]
)
