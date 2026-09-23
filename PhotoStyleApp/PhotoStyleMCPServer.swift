import AppKit
import Network

/// Embedded, authenticated MCP Streamable HTTP endpoint, restricted to IPv4 loopback.
final class PhotoStyleMCPServer {
    static let defaultPort: UInt16 = 8765
    static let versions = ["2025-11-25", "2025-06-18", "2025-03-26"]
    private let port: UInt16
    private let directory: URL
    private let readTimeout: TimeInterval
    private let processingTimeout: TimeInterval
    private let queue = DispatchQueue(label: "person.vader.PhotoStyleApp.mcp")
    private var listener: NWListener?
    private var connections: [UUID: PhotoStyleMCPHTTPConnection] = [:]
    private struct ActiveRequest {
        let rpcID: String
        let task: Task<Void, Never>
        let deadline: Task<Void, Never>
    }
    private var requests: [UUID: ActiveRequest] = [:]
    private var token = ""
    private(set) var status = "尚未啟動"
    private(set) var isRunning = false
    var onStatusChange: (() -> Void)?
    var toolHandler: ((String, [String: Any]) async throws -> [String: Any])?
    var endpoint: String { "http://127.0.0.1:\(port)/mcp" }
    var connectionFile: URL { directory.appendingPathComponent("connection.json") }

    init(port: UInt16 = defaultPort, directory: URL? = nil, readTimeout: TimeInterval = 15, processingTimeout: TimeInterval = 120) {
        self.port = port
        self.readTimeout = readTimeout
        self.processingTimeout = processingTimeout
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoStyleApp/MCP", isDirectory: true)
    }

    func start() {
        precondition(Thread.isMainThread)
        guard listener == nil else { return }
        do {
            try prepareCredentials()
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(IPv4Address("127.0.0.1")!), port: NWEndpoint.Port(rawValue: port)!)
            let newListener = try NWListener(using: parameters)
            listener = newListener
            status = "啟動中"
            newListener.stateUpdateHandler = { [weak self, weak newListener] state in
                DispatchQueue.main.async {
                    guard let self, let newListener, self.listener === newListener else { return }
                    switch state {
                    case .ready: self.isRunning = true; self.status = "運作中（僅限本機）"
                    case .failed(let error):
                        self.isRunning = false
                        self.status = "無法啟動：\(error.localizedDescription)"
                        self.listener?.cancel()
                        self.listener = nil
                        self.cancelActiveRequests()
                    default: return
                    }
                    self.onStatusChange?()
                }
            }
            newListener.newConnectionHandler = { [weak self, weak newListener] connection in
                // Listener, credentials, request tasks and status belong to the main queue.
                // In particular, a late callback from a stopped listener must not enter a new run.
                DispatchQueue.main.async {
                    guard let self, let newListener, self.listener === newListener,
                          self.connections.count < 32 else { connection.cancel(); return }
                    let id = UUID()
                    let request = PhotoStyleMCPHTTPConnection(
                        connection: connection, queue: self.queue, readTimeout: self.readTimeout,
                        processingTimeout: self.processingTimeout,
                        handler: { [weak self] method, path, headers, body, reply in
                            DispatchQueue.main.async {
                                guard let self, self.listener === newListener, self.connections[id] != nil else {
                                    reply(503, nil); return
                                }
                                self.handle(connectionID: id, method: method, path: path, headers: headers, body: body, reply: reply)
                            }
                        }, onTimeout: { [weak self] in
                            DispatchQueue.main.async { self?.requests[id]?.task.cancel() }
                        }, onClose: { [weak self] in
                            DispatchQueue.main.async { self?.connections.removeValue(forKey: id) }
                        })
                    self.connections[id] = request
                    self.queue.async { request.start() }
                }
            }
            newListener.start(queue: queue)
        } catch {
            status = "無法啟動：\(error.localizedDescription)"
            isRunning = false
        }
        onStatusChange?()
    }

    func stop() {
        precondition(Thread.isMainThread)
        listener?.cancel()
        listener = nil
        cancelActiveRequests()
        isRunning = false
        status = "已停用"
        onStatusChange?()
    }

    private func cancelActiveRequests() {
        requests.values.forEach { $0.task.cancel(); $0.deadline.cancel() }
        // Keep unfinished tasks counted until they actually return; cancellation is cooperative.
        let active = Array(connections.values)
        connections.removeAll()
        queue.async { active.forEach { $0.cancel() } }
    }

    func copyConnectionConfiguration() {
        guard let data = try? Data(contentsOf: connectionFile), let text = String(data: data, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func prepareCredentials() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if let data = try? Data(contentsOf: connectionFile),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let servers = json["mcpServers"] as? [String: Any], let server = servers["FilmYourPhoto"] as? [String: Any],
           let headers = server["headers"] as? [String: String], let auth = headers["Authorization"], auth.hasPrefix("Bearer ") {
            token = String(auth.dropFirst(7))
        }
        if token.count < 32 { token = UUID().uuidString + UUID().uuidString }
        let configuration: [String: Any] = ["mcpServers": ["FilmYourPhoto": ["url": endpoint, "headers": ["Authorization": "Bearer \(token)"]]]]
        let data = try JSONSerialization.data(withJSONObject: configuration, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        // Create with owner-only permissions before writing any credential bytes.
        if !fm.fileExists(atPath: connectionFile.path) {
            guard fm.createFile(atPath: connectionFile.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: connectionFile.path)
        let handle = try FileHandle(forWritingTo: connectionFile)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: data)
    }

    private func handle(connectionID: UUID, method: String, path: String, headers: [String: String], body: Data, reply: @escaping PhotoStyleMCPHTTPConnection.Reply) {
        let hosts = ["127.0.0.1:\(port)", "localhost:\(port)"]
        guard hosts.contains(headers["host"]?.lowercased() ?? "") else { reply(403, nil); return }
        if let origin = headers["origin"] {
            guard let url = URL(string: origin), url.scheme == "http",
                  url.user == nil, url.password == nil, url.path.isEmpty, url.query == nil, url.fragment == nil,
                  ["127.0.0.1", "localhost"].contains(url.host?.lowercased() ?? ""), url.port == Int(port) else { reply(403, nil); return }
        }
        guard authorized(headers["authorization"] ?? "") else { reply(401, nil); return }
        guard path == "/mcp" else { reply(404, nil); return }
        guard method == "POST" else { reply(405, nil); return }
        let mediaType = headers["content-type"]?.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces).lowercased()
        guard mediaType == "application/json" else { reply(415, nil); return }
        if let version = headers["mcp-protocol-version"], !Self.versions.contains(version) { reply(400, nil); return }
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: body) }
        catch { reply(400, Self.error(id: NSNull(), code: -32700, message: "Parse error")); return }
        guard let request = object as? [String: Any], request["jsonrpc"] as? String == "2.0",
              let rpcMethod = request["method"] as? String else {
            reply(400, Self.error(id: NSNull(), code: -32600, message: "Invalid request")); return
        }
        guard request["params"] == nil || request["params"] is [String: Any] else {
            if let id = request["id"], Self.requestID(id) != nil {
                reply(200, Self.error(id: id, code: -32602, message: "params must be an object"))
            } else { reply(400, Self.error(id: NSNull(), code: -32600, message: "Invalid request")) }
            return
        }
        guard let id = request["id"] else {
            if rpcMethod == "notifications/cancelled",
               let params = request["params"] as? [String: Any],
               let requestID = params["requestId"].flatMap(Self.requestID) {
                let matching = requests.filter { $0.value.rpcID == requestID }
                // This stateless endpoint can serve multiple clients using the same numeric ID.
                // An ambiguous notification cannot safely identify one client's request.
                if matching.count == 1, let entry = matching.first {
                    entry.value.task.cancel()
                    if let connection = connections[entry.key] { queue.async { connection.cancel() } }
                }
            }
            reply(202, nil); return
        }
        guard let rpcID = Self.requestID(id) else {
            reply(400, Self.error(id: NSNull(), code: -32600, message: "Invalid request ID")); return
        }
        let params = request["params"] as? [String: Any] ?? [:]
        func result(_ value: [String: Any]) { reply(200, ["jsonrpc": "2.0", "id": id, "result": value]) }
        switch rpcMethod {
        case "initialize":
            guard let requested = params["protocolVersion"] as? String else {
                reply(200, Self.error(id: id, code: -32602, message: "protocolVersion is required")); return
            }
            result(["protocolVersion": Self.versions.contains(requested) ? requested : Self.versions[0],
                    "capabilities": ["tools": ["listChanged": false]],
                    "serverInfo": ["name": "FilmYourPhoto", "version": "1.0.0"],
                    "instructions": "操作會同步更新 macOS App。匯出預設不覆寫；AI 分析完成前請以 get_state 查詢進度。"])
        case "ping": result([:])
        case "tools/list": result(["tools": PhotoStyleMCPTools.definitions])
        case "tools/call":
            guard let name = params["name"] as? String, PhotoStyleMCPTools.names.contains(name),
                  params["arguments"] == nil || params["arguments"] is [String: Any] else {
                reply(200, Self.error(id: id, code: -32602, message: "Unknown tool or invalid arguments")); return
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            guard requests.count < 32 else { reply(503, nil); return }
            let task = Task { @MainActor [weak self] in
                guard let self else { reply(503, nil); return }
                defer { self.requests.removeValue(forKey: connectionID)?.deadline.cancel() }
                guard !Task.isCancelled, self.connections[connectionID] != nil,
                      let handler = self.toolHandler else { reply(503, nil); return }
                do {
                    let value = try await handler(name, arguments)
                    guard !Task.isCancelled else { return }
                    result(value)
                } catch {
                    guard !Task.isCancelled else { return }
                    result(["isError": true, "content": [["type": "text", "text": error.localizedDescription]]])
                }
            }
            // A transport failure is not an MCP cancellation notification. Let an accepted
            // operation finish, but retain its deadline even if its TCP connection disappears.
            let interval = processingTimeout
            let deadline = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000)) }
                catch { return }
                self?.requests[connectionID]?.task.cancel()
            }
            requests[connectionID] = ActiveRequest(rpcID: rpcID, task: task, deadline: deadline)
        default: reply(200, Self.error(id: id, code: -32601, message: "Method not found"))
        }
    }

    private static func requestID(_ value: Any) -> String? {
        if let text = value as? String { return "string:" + text }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return "number:" + number.stringValue
        }
        return nil
    }

    private func authorized(_ value: String) -> Bool {
        let expected = Array("Bearer \(token)".utf8), actual = Array(value.utf8)
        guard expected.count == actual.count else { return false }
        return zip(expected, actual).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private static func error(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }
}
