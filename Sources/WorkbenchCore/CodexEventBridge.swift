import Foundation
import Network

/// Metadata-only lifecycle message. The index/reader, not the sender, authorizes a session.
public struct CodexHookStatus: Codable, Equatable, Sendable {
    public var version: Int
    public var sessionID: String
    public var turnID: String
    public var cwd: String
    public var event: String
    public var updatedAt: String
    public init(version: Int = 1, sessionID: String, turnID: String, cwd: String, event: String, updatedAt: String) {
        self.version = version; self.sessionID = sessionID; self.turnID = turnID
        self.cwd = cwd; self.event = event; self.updatedAt = updatedAt
    }
}

public struct CodexBridgeEvent: Codable, Sendable {
    public var version = 1
    public var kind: String
    public var hook: CodexHookStatus?
    public var receiptPath: String?
    public init(hook: CodexHookStatus) { kind = "hook"; self.hook = hook }
    public init(receiptURL: URL) { kind = "dispatch"; receiptPath = receiptURL.path }
    var isValid: Bool {
        guard version == 1 else { return false }
        if kind == "dispatch" { return hook == nil && receiptPath?.hasPrefix("/") == true && (receiptPath?.utf8.count ?? 0) <= 4096 }
        guard kind == "hook", receiptPath == nil, let h = hook else { return false }
        return h.version == 1 && !h.sessionID.isEmpty && h.sessionID.utf8.count <= 4096
            && !h.turnID.isEmpty && h.turnID.utf8.count <= 4096 && h.cwd.hasPrefix("/") && h.cwd.utf8.count <= 4096
            && ["UserPromptSubmit", "Stop", "Interrupt"].contains(h.event) && h.updatedAt.count <= 64
    }
}

private struct BridgeEndpoint: Codable {
    var version = 1
    var url: String
    var token: String
}

public enum CodexBridgeClient {
    public static var defaultEndpointURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/codex-tasks-bridge/endpoint.json")
    }
    /// Bounded best effort. The receipt/sidecar is already durable before this call.
    @discardableResult public static func notify(_ event: CodexBridgeEvent, endpointURL: URL = defaultEndpointURL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: endpointURL.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 4096,
              let data = try? Data(contentsOf: endpointURL), let endpoint = try? JSONDecoder().decode(BridgeEndpoint.self, from: data),
              endpoint.version == 1, endpoint.token.count == 64,
              let url = URL(string: endpoint.url), url.scheme == "http", url.host == "127.0.0.1", url.port != nil,
              url.path == "/v1/events", url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              let body = try? JSONEncoder().encode(event) else { return false }
        var request = URLRequest(url: url, timeoutInterval: 0.2)
        request.httpMethod = "POST"; request.httpBody = body
        request.setValue("Bearer " + endpoint.token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 0.2; config.timeoutIntervalForResource = 0.2
        let session = URLSession(configuration: config), done = DispatchSemaphore(value: 0)
        // This lock also protects against a completion arriving just after the timeout.
        let result = BridgeResult()
        let task = session.dataTask(with: request) { _, response, _ in
            result.set((response as? HTTPURLResponse)?.statusCode == 202); done.signal()
        }
        task.resume()
        let finished = done.wait(timeout: .now() + 0.25) == .success
        task.cancel(); session.invalidateAndCancel()
        return finished && result.get()
    }
}
private final class BridgeResult: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    func set(_ value: Bool) { lock.lock(); self.value = value; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// A small HTTP/1.1 endpoint bound explicitly to IPv4 loopback. No remote control APIs.
public final class CodexEventBridge {
    private let queue = DispatchQueue(label: "workbench.codex-http", qos: .userInitiated)
    private let endpointURL: URL
    private let token = UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    private let listener: NWListener
    private let onEvent: (CodexBridgeEvent) -> Void
    private var connections: [UUID: NWConnection] = [:]
    private var stopped = false
    public init(endpointURL: URL = CodexBridgeClient.defaultEndpointURL, onEvent: @escaping (CodexBridgeEvent) -> Void) throws {
        self.endpointURL = endpointURL; self.onEvent = onEvent
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }
    public func start(onReady: @escaping (Bool) -> Void = { _ in }) {
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard !self.stopped, let port = self.listener.port else { return }
                do {
                    let directory = self.endpointURL.deletingLastPathComponent()
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
                    let endpoint = BridgeEndpoint(url: "http://127.0.0.1:\(port.rawValue)/v1/events", token: self.token)
                    // Directory is private throughout the atomic replacement.
                    try JSONEncoder().encode(endpoint).write(to: self.endpointURL, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.endpointURL.path)
                    onReady(true)
                } catch { self.stopOnQueue(); onReady(false) }
            case .failed: self.stopOnQueue(); onReady(false)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
    }
    public func stop() { queue.sync { stopOnQueue() } }
    private func stopOnQueue() {
        guard !stopped else { return }; stopped = true
        listener.cancel()
        for connection in connections.values { connection.cancel() }; connections.removeAll()
        if let data = try? Data(contentsOf: endpointURL), let endpoint = try? JSONDecoder().decode(BridgeEndpoint.self, from: data), endpoint.token == token {
            try? FileManager.default.removeItem(at: endpointURL)
        }
    }
    private func accept(_ connection: NWConnection) {
        guard !stopped, connections.count < 32 else { connection.cancel(); return }
        let id = UUID(); connections[id] = connection
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 2) { [weak self, weak connection] in
            connection?.cancel(); self?.connections.removeValue(forKey: id)
        }
        receive(connection, id: id, buffer: Data())
    }
    private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 20 * 1024) { [weak self] data, _, complete, error in
            guard let self, self.connections[id] != nil else { return }
            var bytes = buffer; if let data { bytes.append(data) }
            guard bytes.count <= 20 * 1024 else { self.respond(413, connection, id); return }
            if let end = bytes.range(of: Data("\r\n\r\n".utf8)) {
                guard end.upperBound <= 4096, let header = String(data: bytes[..<end.lowerBound], encoding: .utf8) else { self.respond(400, connection, id); return }
                let lines = header.components(separatedBy: "\r\n")
                guard lines.first == "POST /v1/events HTTP/1.1" else { self.respond(404, connection, id); return }
                var fields: [String: String] = [:]
                for line in lines.dropFirst() {
                    guard let colon = line.firstIndex(of: ":") else { self.respond(400, connection, id); return }
                    let key = line[..<colon].lowercased(), value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    guard fields[key] == nil else { self.respond(400, connection, id); return }; fields[key] = value
                }
                guard fields["authorization"] == "Bearer " + self.token else { self.respond(401, connection, id); return }
                guard fields["transfer-encoding"] == nil, let raw = fields["content-length"], let length = Int(raw), length > 0, length <= 16 * 1024 else { self.respond(400, connection, id); return }
                let received = bytes.count - end.upperBound
                if received >= length {
                    guard received == length, let event = try? JSONDecoder().decode(CodexBridgeEvent.self, from: Data(bytes[end.upperBound...])), event.isValid else { self.respond(400, connection, id); return }
                    self.onEvent(event); self.respond(202, connection, id); return
                }
            } else if bytes.count > 4096 { self.respond(413, connection, id); return }
            guard !complete, error == nil else { self.respond(400, connection, id); return }
            self.receive(connection, id: id, buffer: bytes)
        }
    }
    private func respond(_ code: Int, _ connection: NWConnection, _ id: UUID) {
        let response = Data("HTTP/1.1 \(code) Response\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            connection.cancel(); self?.connections.removeValue(forKey: id)
        })
    }
}
