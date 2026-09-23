import Foundation
import Network

/// One bounded HTTP request per TCP connection. MCP uses JSON responses, not SSE.
/// All mutable connection state is confined to the supplied network queue.
final class PhotoStyleMCPHTTPConnection {
    typealias Reply = (Int, [String: Any]?) -> Void
    typealias Handler = (String, String, [String: String], Data, @escaping Reply) -> Void
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let handler: Handler
    private let onClose: () -> Void
    private let onTimeout: () -> Void
    private let readTimeout: TimeInterval
    private let processingTimeout: TimeInterval
    private var buffer = Data()
    private var responded = false
    private var closed = false
    private var timeout: DispatchWorkItem?
    private static let maxBodySize = 1_048_576
    private static let maxHeaderSize = 16_384

    init(connection: NWConnection, queue: DispatchQueue, readTimeout: TimeInterval = 15,
         processingTimeout: TimeInterval = 120, handler: @escaping Handler,
         onTimeout: @escaping () -> Void = {}, onClose: @escaping () -> Void) {
        self.connection = connection
        self.queue = queue
        self.readTimeout = readTimeout
        self.processingTimeout = processingTimeout
        self.handler = handler
        self.onTimeout = onTimeout
        self.onClose = onClose
    }

    func start() {
        scheduleTimeout(after: readTimeout, status: 408)
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.close() }
            if case .cancelled = state { self?.close() }
        }
        connection.start(queue: queue)
        receive()
    }

    func cancel() { close() }

    private func scheduleTimeout(after interval: TimeInterval, status: Int?) {
        timeout?.cancel()
        let deadline = DispatchWorkItem { [weak self] in
            guard let self, !self.closed else { return }
            self.onTimeout()
            if let status { self.respond(status, nil) } else { self.close() }
        }
        timeout = deadline
        queue.asyncAfter(deadline: .now() + interval, execute: deadline)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self, !self.closed, !self.responded else { return }
            if let data { self.buffer.append(data) }
            if self.parse() { return }
            if complete || error != nil { self.close() } else { self.receive() }
        }
    }

    private func parse() -> Bool {
        guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > Self.maxHeaderSize { respond(431, nil); return true }
            return false
        }
        guard separator.lowerBound <= Self.maxHeaderSize else { respond(431, nil); return true }
        guard let header = String(data: buffer[..<separator.lowerBound], encoding: .utf8) else {
            respond(400, nil); return true
        }
        let lines = header.components(separatedBy: "\r\n")
        let request = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard request.count == 3, !request[0].isEmpty, !request[1].isEmpty,
              request[2] == "HTTP/1.1" || request[2] == "HTTP/1.0" else {
            respond(400, nil); return true
        }
        var headers: [String: String] = [:]
        let tokenCharacters = Set("!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".utf8)
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { respond(400, nil); return true }
            let name = line[..<colon].lowercased()
            let rawValue = line[line.index(after: colon)...]
            guard !name.isEmpty, name.utf8.allSatisfy({ tokenCharacters.contains($0) }),
                  rawValue.utf8.allSatisfy({ $0 == 9 || $0 >= 32 && $0 != 127 }),
                  headers[name] == nil else { respond(400, nil); return true }
            headers[name] = rawValue.trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil else { respond(400, nil); return true }
        let method = String(request[0])
        if method == "POST", headers["content-length"] == nil { respond(411, nil); return true }
        let lengthText = headers["content-length"] ?? "0"
        guard !lengthText.isEmpty, lengthText.utf8.allSatisfy({ (48...57).contains($0) }),
              let length = Int(lengthText) else { respond(400, nil); return true }
        guard length <= Self.maxBodySize else { respond(413, nil); return true }
        let bodyStart = separator.upperBound
        guard buffer.count >= bodyStart + length else { return false }
        scheduleTimeout(after: processingTimeout, status: 504)
        let body = buffer.subdata(in: bodyStart..<(bodyStart + length))
        buffer.removeAll(keepingCapacity: false)
        handler(method, String(request[1]), headers, body) { [weak self] status, payload in
            guard let self else { return }
            self.queue.async { self.respond(status, payload) }
        }
        return true
    }

    private func respond(_ status: Int, _ payload: [String: Any]?) {
        guard !responded, !closed else { return }
        responded = true
        // A client that stops reading a large preview must not retain a slot forever.
        scheduleTimeout(after: readTimeout, status: nil)
        var responseStatus = status
        let body: Data
        if let payload {
            if JSONSerialization.isValidJSONObject(payload),
               let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) {
                body = data
            } else { responseStatus = 500; body = Data() }
        } else { body = Data() }
        let phrases = [200:"OK",202:"Accepted",400:"Bad Request",401:"Unauthorized",403:"Forbidden",404:"Not Found",405:"Method Not Allowed",408:"Request Timeout",411:"Length Required",413:"Content Too Large",415:"Unsupported Media Type",431:"Request Header Fields Too Large",500:"Internal Server Error",503:"Service Unavailable",504:"Gateway Timeout"]
        var header = "HTTP/1.1 \(responseStatus) \(phrases[responseStatus] ?? "Error")\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n"
        if responseStatus == 401 { header += "WWW-Authenticate: Bearer realm=\"FilmYourPhoto\"\r\n" }
        if responseStatus == 405 { header += "Allow: POST\r\n" }
        var response = Data((header + "\r\n").utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in self?.close() })
    }

    private func close() {
        guard !closed else { return }
        closed = true
        buffer.removeAll(keepingCapacity: false)
        timeout?.cancel()
        timeout = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        onClose()
    }
}
