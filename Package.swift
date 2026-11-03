// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "FloatingWorkbench",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "WorkbenchCore", targets: ["WorkbenchCore"]),
        .executable(name: "WorkbenchCLI", targets: ["WorkbenchCLI"]),
        .executable(name: "CodexTaskRunner", targets: ["CodexTaskRunner"]),
        .executable(name: "CodexStatusHook", targets: ["CodexStatusHook"]),
        .executable(name: "FloatingWorkbench", targets: ["FloatingWorkbench"]),
        .executable(name: "WorkbenchAcceptance", targets: ["WorkbenchAcceptance"])
    ],
    targets: [
        .target(name: "WorkbenchFlowUI", dependencies: ["WorkbenchCore"]),
        .executableTarget(name: "FlowUIAcceptance", dependencies: ["WorkbenchCore", "WorkbenchFlowUI"], path: "Tests/FlowUI"),
        .executableTarget(name: "CICDAcceptance", dependencies: ["WorkbenchCore", "CSQLite"], path: "Tests/CICD"),
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "WorkbenchCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "WorkbenchCLI", dependencies: ["WorkbenchCore"]),
        .executableTarget(name: "CodexTaskRunner", dependencies: ["WorkbenchCore"]),
        .executableTarget(name: "CodexStatusHook", dependencies: ["WorkbenchCore"]),
        .executableTarget(name: "FloatingWorkbench", dependencies: ["WorkbenchCore", "WorkbenchFlowUI"]),
        .executableTarget(name: "WorkbenchAcceptance", dependencies: ["WorkbenchCore", "CSQLite"], path: "Tests/Acceptance")
    ]
)
