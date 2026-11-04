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
    let manager = FileManager.default
    let projectURL = appURL.deletingLastPathComponent().deletingLastPathComponent()
    let home = manager.homeDirectoryForCurrentUser
    let applicationRoots = [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
    let trashURL = home.appendingPathComponent(".Trash")
    let registrar = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    func isWithin(_ url: URL, _ root: URL) -> Bool {
        url.path.hasPrefix(root.path + "/")
    }
    func isProjectBundle(_ identifier: String) -> Bool {
        identifier == bundleID || identifier.hasPrefix(bundleID + ".") || identifier.hasPrefix("ai.sunkey.codextasks.")
    }
    @discardableResult func registration(_ arguments: [String]) -> String {
        // Trash relocation is asynchronous in Launch Services; retry that path briefly.
        for attempt in 0..<3 {
            let process = Process(), output = Pipe(), errors = Pipe()
            process.executableURL = URL(fileURLWithPath: registrar)
            process.arguments = arguments; process.standardOutput = output; process.standardError = errors
            do {
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let error = errors.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus == 0 { return String(decoding: data, as: UTF8.self) }
                if arguments.first == "-u", attempt < 2 {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                    continue
                }
                fail("启动项登记更新失败：\(arguments) \(String(decoding: error, as: UTF8.self))")
            } catch { fail("无法更新启动项：\(error.localizedDescription)") }
        }
        fail("启动项登记更新失败：\(arguments)")
    }
    var candidates = Set<URL>()
    // Inspect only this project's temporary/output folders and application folders.
    for root in [projectURL.appendingPathComponent("work"), appURL.deletingLastPathComponent()] + applicationRoots {
        guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { continue }
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                enumerator.skipDescendants(); continue
            }
            guard url.pathExtension == "app" else { continue }
            enumerator.skipDescendants()
            if let id = Bundle(url: url)?.bundleIdentifier, isProjectBundle(id) { candidates.insert(url) }
        }
    }
    // Include stale Launch Services entries, including applications already in Trash.
    let registrations = registration(["-dump"])
    for block in registrations.components(separatedBy: "--------------------------------------------------------------------------------") {
        var path: String?, identifier: String?
        for line in block.components(separatedBy: .newlines) {
            if line.hasPrefix("path:") {
                let value = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                path = value.components(separatedBy: " (0x").first
            } else if line.hasPrefix("identifier:") {
                identifier = String(line.dropFirst(11)).trimmingCharacters(in: .whitespaces)
            }
        }
        guard let path, let identifier, isProjectBundle(identifier) else { continue }
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard isWithin(url, projectURL) || isWithin(url, trashURL) || applicationRoots.contains(where: { isWithin(url, $0) }) else { continue }
        candidates.insert(url)
    }
    for candidate in candidates.sorted(by: { $0.path < $1.path }) {
        let url = candidate.standardizedFileURL.resolvingSymlinksInPath()
        guard url != appURL else { continue }
        // Recheck identity before touching an existing bundle.
        if manager.fileExists(atPath: url.path) {
            guard let id = Bundle(url: url)?.bundleIdentifier, isProjectBundle(id) else { continue }
        }
        registration(["-u", url.path])
        if manager.fileExists(atPath: url.path), !isWithin(url, trashURL) {
            do {
                var trashed: NSURL?
                try manager.trashItem(at: url, resultingItemURL: &trashed)
                if let trashed { registration(["-u", trashed.path!]) }
                print("重复应用已移到废纸篓：\(url.path)")
            } catch { fail("旧包清理失败：\(error.localizedDescription)") }
        } else { print("已移除旧启动项登记：\(url.path)") }
    }
    registration(["-f", appURL.path])
    print("保留唯一正式启动项：\(appURL.path)")
case "verify":
    guard waitUntil(10, {
        let apps = runningApps()
        return apps.count == 1 && apps[0].bundleURL?.standardizedFileURL.resolvingSymlinksInPath() == appURL
    }) else { fail("未确认新版唯一运行，请检查应用启动情况。") }
    print("已启动新版：\(appURL.path)（PID \(runningApps()[0].processIdentifier)）")
default:
    fail("未知操作：\(arguments[0])")
}
