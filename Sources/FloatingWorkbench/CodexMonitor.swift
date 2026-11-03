import Foundation
import CoreServices

/// Watches Codex metadata only. SHM is excluded to avoid feedback from our own SQLite reads.
final class CodexMonitor {
    private var stream: FSEventStreamRef?
    private let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").resolvingSymlinksInPath().path
    private let onChange: () -> Void
    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        stream = FSEventStreamCreate(nil, { _, info, count, rawPaths, flags, _ in
            guard let info else { return }
            let monitor = Unmanaged<CodexMonitor>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(rawPaths, to: NSArray.self) as? [String] ?? []
            let dropped = (0..<count).contains { flags[$0] & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0 }
            if dropped || paths.contains(where: monitor.relevant) { monitor.onChange() }
        }, &context, [home] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.15,
        FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            if !FSEventStreamStart(stream) { FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); self.stream = nil }
        }
    }
    private func relevant(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        return (url.deletingLastPathComponent().path == home && url.lastPathComponent.range(of: "^state_[0-9]+\\.sqlite(?:-wal)?$", options: .regularExpression) != nil)
            || ((path.hasPrefix(home + "/sessions/") || path.hasPrefix(home + "/archived_sessions/")) && path.hasSuffix(".jsonl"))
    }
    deinit { if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) } }
}
