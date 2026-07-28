import Foundation
import Network

/// Executes one HTTP/1.1 request while requiring a specific local source IP.
/// HTTPS uses Network.framework's default TLS verification and never falls back
/// to cleartext when validation or source binding fails.
final class SourceBoundHTTPTransport {
    func execute(
        _ request: URLRequest,
        sourceIP: String,
        timeout: TimeInterval
    ) async throws -> HTTPResponse {
        guard let url = request.url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? (scheme == "https" ? 443 : 80))) else {
            throw SZUNetError.network("源地址绑定失败：请求 URL 无效。")
        }
        let parameters: NWParameters
        if scheme == "https" {
            parameters = NWParameters(tls: NWProtocolTLS.Options(), tcp: NWProtocolTCP.Options())
        } else {
            parameters = .tcp
        }
        parameters.preferNoProxies = true
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host(sourceIP),
            port: .any
        )
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
        let wireRequest = try Self.makeWireRequest(request, host: host, port: port.rawValue, scheme: scheme)
        let operation = SourceBoundRequestOperation(
            connection: connection,
            request: wireRequest,
            responseURL: url,
            expectedSourceHost: NWEndpoint.Host(sourceIP),
            timeout: timeout
        )
        return try await withTaskCancellationHandler {
            try await operation.run()
        } onCancel: {
            operation.cancel()
        }
    }

    private static func makeWireRequest(
        _ request: URLRequest,
        host: String,
        port: UInt16,
        scheme: String
    ) throws -> Data {
        guard let url = request.url else { throw SZUNetError.network("源地址绑定失败：请求 URL 无效。") }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw SZUNetError.network("源地址绑定失败：请求 URL 无效。")
        }
        var target = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        if let query = components.percentEncodedQuery, !query.isEmpty { target += "?\(query)" }
        var headers = request.allHTTPHeaderFields ?? [:]
        let defaultPort: UInt16 = scheme == "https" ? 443 : 80
        headers["Host"] = port == defaultPort ? host : "\(host):\(port)"
        headers["Connection"] = "close"
        headers["Accept-Encoding"] = "identity"
        for (name, value) in headers where
            name.contains("\r") || name.contains("\n") || value.contains("\r") || value.contains("\n") {
            throw SZUNetError.network("源地址绑定失败：HTTP 标头无效。")
        }
        let method = request.httpMethod ?? "GET"
        var lines = ["\(method) \(target) HTTP/1.1"]
        lines.append(contentsOf: headers.sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { "\($0.key): \($0.value)" })
        lines.append("")
        lines.append("")
        var data = Data(lines.joined(separator: "\r\n").utf8)
        if let body = request.httpBody { data.append(body) }
        return data
    }
}

private final class SourceBoundRequestOperation: @unchecked Sendable {
    private static let maximumResponseBytes = 4 * 1_024 * 1_024
    private let connection: NWConnection
    private let request: Data
    private let responseURL: URL
    private let expectedSourceHost: NWEndpoint.Host
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: "SZUNetCore.SourceBoundHTTPTransport")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<HTTPResponse, Error>?
    private var completed = false
    private var received = Data()
    private var lastEvent = "setup"

    init(
        connection: NWConnection,
        request: Data,
        responseURL: URL,
        expectedSourceHost: NWEndpoint.Host,
        timeout: TimeInterval
    ) {
        self.connection = connection
        self.request = request
        self.responseURL = responseURL
        self.expectedSourceHost = expectedSourceHost
        self.timeout = max(0.1, timeout)
    }

    func run() async throws -> HTTPResponse {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if completed {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation
            lock.unlock()
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .preparing:
                    self.lastEvent = "preparing"
                case .waiting(let error):
                    self.lastEvent = "waiting_\(Self.reason(error))"
                case .ready:
                    self.lastEvent = "ready"
                    guard let localEndpoint = self.connection.currentPath?.localEndpoint,
                          case let .hostPort(actualHost, _) = localEndpoint,
                          actualHost == self.expectedSourceHost else {
                        self.finish(.failure(SZUNetError.network(
                            "源地址绑定失败：实际本地端点与已验证源地址不一致。"
                        )))
                        return
                    }
                    self.sendRequest()
                case .failed(let error):
                    self.lastEvent = "failed_\(Self.reason(error))"
                    self.finish(.failure(SZUNetError.network("源地址绑定失败：\(Self.reason(error))")))
                case .cancelled:
                    self.lastEvent = "cancelled"
                    self.finish(.failure(CancellationError()))
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                self.finish(.failure(SZUNetError.network(
                    "源地址绑定请求超时（阶段：\(self.lastEvent)）。"
                )))
            }
        }
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }

    private func sendRequest() {
        lastEvent = "sending"
        connection.send(content: request, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error {
                self.lastEvent = "send_failed_\(Self.reason(error))"
                self.finish(.failure(SZUNetError.network("源地址绑定发送失败：\(Self.reason(error))")))
            } else {
                self.lastEvent = "sent"
                self.receiveNext()
            }
        })
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.received.append(data) }
            self.lastEvent = "received_\(self.received.count)_complete_\(isComplete)"
            if self.received.count > Self.maximumResponseBytes {
                self.finish(.failure(SZUNetError.network("源地址绑定响应超过大小限制。")))
                return
            }
            do {
                if try Self.hasCompleteContentLengthResponse(self.received) {
                    self.finish(.success(try Self.parse(self.received, url: self.responseURL)))
                    return
                }
            } catch {
                self.finish(.failure(error))
                return
            }
            if let error {
                self.finish(.failure(SZUNetError.network("源地址绑定接收失败：\(Self.reason(error))")))
            } else if isComplete {
                do {
                    self.finish(.success(try Self.parse(self.received, url: self.responseURL)))
                } catch {
                    self.finish(.failure(error))
                }
            } else {
                self.receiveNext()
            }
        }
    }

    private static func hasCompleteContentLengthResponse(_ data: Data) throws -> Bool {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: separator) else { return false }
        let headers = try parseHeaders(data[..<headerRange.lowerBound])
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            return false
        }
        guard let rawLength = headers["content-length"] else { return false }
        guard let contentLength = Int(rawLength),
              contentLength >= 0,
              contentLength <= maximumResponseBytes else {
            throw SZUNetError.network("源地址绑定响应的 Content-Length 无效。")
        }
        return data.count - headerRange.upperBound >= contentLength
    }

    private func finish(_ result: Result<HTTPResponse, Error>) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation?.resume(with: result)
    }

    private static func parse(_ data: Data, url: URL) throws -> HTTPResponse {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: separator),
              let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else {
            throw SZUNetError.network("源地址绑定响应不是有效 HTTP。")
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else {
            throw SZUNetError.network("源地址绑定响应缺少状态行。")
        }
        let statusParts = statusLine.split(separator: " ", maxSplits: 2)
        guard statusParts.count >= 2, let statusCode = Int(statusParts[1]) else {
            throw SZUNetError.network("源地址绑定响应状态无效。")
        }
        let headers = try parseHeaders(data[..<headerRange.lowerBound])
        let bodyStart = headerRange.upperBound
        var body = Data(data[bodyStart...])
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            body = try decodeChunked(body)
        } else if let rawLength = headers["content-length"],
                  let contentLength = Int(rawLength) {
            guard body.count >= contentLength else {
                throw SZUNetError.network("源地址绑定响应正文不完整。")
            }
            body = Data(body.prefix(contentLength))
        }
        return HTTPResponse(statusCode: statusCode, headers: headers, body: body, finalURL: url)
    }

    private static func parseHeaders(_ data: Data.SubSequence) throws -> [String: String] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw SZUNetError.network("源地址绑定响应标头编码无效。")
        }
        var headers: [String: String] = [:]
        for line in text.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if let existing = headers[name] {
                headers[name] = existing + ", " + value
            } else {
                headers[name] = value
            }
        }
        return headers
    }

    private static func decodeChunked(_ data: Data) throws -> Data {
        var remaining = data
        var decoded = Data()
        let lineBreak = Data("\r\n".utf8)
        while true {
            guard let sizeRange = remaining.range(of: lineBreak),
                  let sizeText = String(data: remaining[..<sizeRange.lowerBound], encoding: .ascii),
                  let size = Int(sizeText.split(separator: ";", maxSplits: 1)[0], radix: 16) else {
                throw SZUNetError.network("源地址绑定响应的分块编码无效。")
            }
            remaining.removeSubrange(..<sizeRange.upperBound)
            if size == 0 { return decoded }
            guard remaining.count >= size + lineBreak.count else {
                throw SZUNetError.network("源地址绑定响应的分块正文不完整。")
            }
            decoded.append(remaining.prefix(size))
            remaining.removeSubrange(..<(size + lineBreak.count))
        }
    }

    private static func reason(_ error: NWError) -> String {
        switch error {
        case .posix(let code): return "posix_\(code.rawValue)"
        case .dns(let code): return "dns_\(code)"
        case .tls(let code): return "tls_\(code)"
        default: return "network_error"
        }
    }
}
