import Foundation
import CoreServices

/// Observe metadata changes only. The reader enforces workspace and rollout-path boundaries.
final class CodexChangeMonitor {
    private var stream: FSEventStreamRef?
    private let home: String
    private let onChanges: (Set<String>?) -> Void
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"), onChanges: @escaping (Set<String>?) -> Void) {
        self.home = home.resolvingSymlinksInPath().path
        self.onChanges = onChanges
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        stream = FSEventStreamCreate(nil, { _, info, count, paths, flags, _ in
            guard let info else { return }
            let monitor = Unmanaged<CodexChangeMonitor>.fromOpaque(info).takeUnretainedValue()
            let changed = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let dropped = (0..<count).contains { flags[$0] & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0 }
            let paths = Set(changed.filter { monitor.relevant($0) })
            if dropped { monitor.onChanges(nil) } else if !paths.isEmpty { monitor.onChanges(paths) }
        }, &context, [self.home] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.15,
        FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            if !FSEventStreamStart(stream) { FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); self.stream = nil }
        }
    }
    convenience init(home: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"), onChange: @escaping () -> Void) {
        self.init(home: home, onChanges: { _ in onChange() })
    }
    var isActive: Bool { stream != nil }
    func relevant(_ path: String) -> Bool {
        // SHM is a coordination file: read-only SQLite clients can update it.
        // Watching it can feed our own reads back into the sync loop.
        let url = URL(fileURLWithPath: path)
        return (url.deletingLastPathComponent().path == home && url.lastPathComponent.range(of: "^state_[0-9]+\\.sqlite(?:-wal)?$", options: .regularExpression) != nil)
            || ((path.hasPrefix(home + "/sessions/") || path.hasPrefix(home + "/archived_sessions/")) && path.hasSuffix(".jsonl"))
            || (url.deletingLastPathComponent().path == home + "/codex-tasks-status" && path.hasSuffix(".json"))
    }
    deinit {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
    }
}
