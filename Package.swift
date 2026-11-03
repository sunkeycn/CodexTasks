// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodexTasksLite",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "FloatingWorkbench", targets: ["FloatingWorkbench"])],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "LiteCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "CodexTasksHook", dependencies: ["LiteCore"]),
        .executableTarget(name: "FloatingWorkbench", dependencies: ["LiteCore"]),
        .executableTarget(name: "LiteAcceptance", dependencies: ["LiteCore", "CSQLite"], path: "Tests/LiteAcceptance")
    ]
)
