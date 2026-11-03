import AppKit
import Darwin

// Keep lifecycle operations scoped to this app, never to the Codex desktop app.
let bundleID = "ai.sunkey.floatingworkbench"
let arguments = Array(CommandLine.arguments.dropFirst())
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}
guard arguments.count == 2 else { fail("Usage: manage-app.swift stop|retire-legacy|verify APP_PATH") }
let appURL = URL(fileURLWithPath: arguments[1]).standardizedFileURL.resolvingSymlinksInPath()
guard Bundle(url: appURL)?.bundleIdentifier == bundleID else { fail("应用标识不匹配：\(appURL.path)") }
func runningApps() -> [NSRunningApplication] {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { !$0.isTerminated }
}
func waitUntil(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    repeat {
        if condition() { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    } while Date() < deadline
    return condition()
}

switch arguments[0] {
case "stop":
    let apps = runningApps()
    for app in apps {
        print("退出旧版 Codex Tasks（PID \(app.processIdentifier)）")
        // Current versions handle SIGTERM on the main queue and release resources.
        // Legacy versions have no handler; their committed SQLite data stays intact.
        guard kill(app.processIdentifier, SIGTERM) == 0 || errno == ESRCH else {
            fail("无法退出旧进程 \(app.processIdentifier)：\(String(cString: strerror(errno)))")
        }
    }
    guard waitUntil(10, { apps.allSatisfy { $0.isTerminated } && runningApps().isEmpty }) else {
        fail("旧版尚未退出，停止替换应用包。")
    }
case "retire-legacy":
    for name in ["悬浮开发工作台.app", "FloatingWorkbench.app"] {
        let legacy = appURL.deletingLastPathComponent().appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: legacy.path) else { continue }
        guard Bundle(url: legacy)?.bundleIdentifier == bundleID else {
            fail("旧包标识不匹配，保留原文件：\(legacy.path)")
        }
        do {
            try FileManager.default.trashItem(at: legacy, resultingItemURL: nil)
            print("旧应用已移到废纸篓：\(name)")
        } catch { fail("旧应用归档失败：\(error.localizedDescription)") }
    }
case "verify":
    guard waitUntil(10, {
        let apps = runningApps()
        return apps.count == 1 && apps[0].bundleURL?.standardizedFileURL.resolvingSymlinksInPath() == appURL
    }) else { fail("未确认新版唯一运行，请检查应用启动情况。") }
    print("已启动新版：\(appURL.path)（PID \(runningApps()[0].processIdentifier)）")
default:
    fail("未知操作：\(arguments[0])")
}
