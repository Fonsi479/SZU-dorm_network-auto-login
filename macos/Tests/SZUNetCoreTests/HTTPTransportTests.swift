import Darwin
import Foundation
import Testing
@testable import SZUNetCore

@Suite("HTTP transport", .serialized)
struct HTTPTransportTests {
    @Test("campus egress probe binds every request to the verified source IP")
    func campusEgressProbeRequiresSourceBinding() async {
        let transport = RecordingDirectTransport()
        var configuration = AppConfiguration.default
        configuration.network.testURLs = [
            "http://captive.apple.com/hotspot-detect.html",
            "http://www.baidu.com/",
        ]
        configuration.network.maxTestURLs = 2
        let probe = CampusDirectEgressProbe(
            configuration: configuration,
            transport: transport,
            logger: AppLogger(fileURL: temporaryHTTPLogURL())
        )

        let result = await probe.check(
            context: CampusNetworkContext(
                generation: 0,
                sourceIP: "192.0.2.27",
                sourceRouteBound: true,
                dormPortalIdentityVerified: true
            )
        )

        #expect(result.available)
        #expect(await transport.sourceIPs == ["192.0.2.27", "192.0.2.27"])
    }

    @Test("URLSession transport clears proxy configuration")
    func transportClearsProxyConfiguration() {
        let configuration = URLSessionConfiguration.ephemeral
        _ = URLSessionHTTPTransport(configuration: configuration)
        #expect(configuration.connectionProxyDictionary?.isEmpty == true)
    }

    @Test("one portal transport keeps cookies across requests")
    func oneTransportKeepsPortalCookiesAcrossRequests() async throws {
        defer { MockURLProtocol.reset() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let transport = URLSessionHTTPTransport(configuration: configuration)

        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path == "/seed" {
                return MockURLProtocol.reply(
                    request: request,
                    headers: ["Set-Cookie": "portal_session=abc123; Path=/"],
                    body: "seeded"
                )
            }
            let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
            return MockURLProtocol.reply(request: request, body: cookie)
        }

        _ = try await transport.get(
            try #require(URL(string: "http://portal.test/seed")),
            query: [:],
            headers: [:],
            timeout: 1,
            sourceIP: nil
        )
        let response = try await transport.get(
            try #require(URL(string: "http://portal.test/check")),
            query: [:],
            headers: [:],
            timeout: 1,
            sourceIP: nil
        )

        #expect(response.bodyText.contains("portal_session=abc123"))
    }

    @Test("cancelling a task cancels its URLSession request")
    func cancellingTaskCancelsURLSessionRequest() async throws {
        defer { MockURLProtocol.reset() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let transport = URLSessionHTTPTransport(configuration: configuration)
        MockURLProtocol.handler = { request in
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return MockURLProtocol.reply(request: request, body: "too late")
        }

        let task = Task {
            try await transport.get(
                try #require(URL(string: "http://portal.test/slow")),
                query: [:],
                headers: [:],
                timeout: 10,
                sourceIP: nil
            )
        }
        let didStart = await waitUntil { MockURLProtocol.didStart }
        #expect(didStart)
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("cancelled transport unexpectedly returned a response")
        } catch is CancellationError {
            // Expected.
        } catch {
            #expect(error.localizedDescription.contains("cancelled"))
        }
        let wasStopped = await waitUntil { MockURLProtocol.wasStopped }
        #expect(wasStopped)
    }

    @Test("source-bound request reaches loopback from the requested local IP")
    func sourceBoundRequestUsesRequestedLoopbackAddress() async throws {
        let server = try LoopbackHTTPServer()
        async let peerIP = server.serveOne()
        let transport = URLSessionHTTPTransport()

        let response = try await transport.get(
            try #require(URL(string: "http://127.0.0.1:\(server.port)/bound")),
            query: [:],
            headers: [:],
            timeout: 2,
            sourceIP: "127.0.0.1"
        )

        #expect(response.statusCode == 200)
        #expect(response.bodyText == "OK")
        #expect(try await peerIP == "127.0.0.1")
    }

    @Test("unavailable source address fails closed without sending a request")
    func unavailableSourceAddressFailsClosed() async throws {
        let server = try LoopbackHTTPServer()
        async let peerIP = server.serveOne(timeoutMilliseconds: 500)
        let transport = URLSessionHTTPTransport()

        do {
            _ = try await transport.get(
                try #require(URL(string: "http://127.0.0.1:\(server.port)/must-not-send")),
                query: [:],
                headers: [:],
                timeout: 1,
                sourceIP: "192.0.2.44"
            )
            Issue.record("transport ignored an unavailable required source address")
        } catch {
            #expect(error.localizedDescription.contains("source") || error.localizedDescription.contains("绑定"))
        }
        #expect(try await peerIP == nil)
    }
}

private actor RecordingDirectTransport: HTTPTransporting {
    private var recordedSourceIPs: [String] = []

    var sourceIPs: [String] {
        recordedSourceIPs
    }

    func get(
        _ url: URL,
        query: [String: String],
        headers: [String: String],
        timeout: TimeInterval,
        sourceIP: String?
    ) async throws -> HTTPResponse {
        recordedSourceIPs.append(sourceIP ?? "")
        return HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data("Success".utf8),
            finalURL: url
        )
    }
}

private func temporaryHTTPLogURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("szunet-http-tests-\(UUID().uuidString).log")
}

private func waitUntil(_ predicate: () -> Bool) async -> Bool {
    for _ in 0..<100 {
        if predicate() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return predicate()
}

private final class LoopbackHTTPServer: @unchecked Sendable {
    private let descriptor: Int32
    let port: UInt16

    init() throws {
        let socketDescriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var reuse: Int32 = 1
        guard setsockopt(
            socketDescriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuse,
            socklen_t(MemoryLayout.size(ofValue: reuse))
        ) == 0 else {
            Darwin.close(socketDescriptor)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            Darwin.close(socketDescriptor)
            throw POSIXError(.EINVAL)
        }
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(socketDescriptor, 1) == 0 else {
            Darwin.close(socketDescriptor)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketDescriptor, $0, &length)
            }
        }
        guard nameResult == 0 else {
            Darwin.close(socketDescriptor)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        descriptor = socketDescriptor
        port = UInt16(bigEndian: bound.sin_port)
    }

    deinit { Darwin.close(descriptor) }

    func serveOne(timeoutMilliseconds: Int32 = 2_000) async throws -> String? {
        let listener = descriptor
        return try await Task.detached {
            var readiness = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            let pollResult = Darwin.poll(&readiness, 1, timeoutMilliseconds)
            guard pollResult > 0 else { return nil }
            var peer = sockaddr_in()
            var peerLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.accept(listener, $0, &peerLength)
                }
            }
            guard client >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            defer { Darwin.close(client) }
            var request = [UInt8](repeating: 0, count: 4_096)
            let bytesRead = request.withUnsafeMutableBytes { buffer in
                Darwin.read(client, buffer.baseAddress, buffer.count)
            }
            guard bytesRead > 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            let response = Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK".utf8)
            try response.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(
                        client,
                        baseAddress.advanced(by: offset),
                        bytes.count - offset
                    )
                    guard written > 0 else {
                        throw POSIXError(.init(rawValue: errno) ?? .EIO)
                    }
                    offset += written
                }
            }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &peer.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            return String(cString: buffer)
        }.value
    }
}

private final class MockURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) async throws -> (HTTPURLResponse, Data)

    private static let stateLock = NSLock()
    private static var handlerStorage: Handler?
    private static var didStartStorage = false
    private static var wasStoppedStorage = false
    private var work: Task<Void, Never>?

    static var handler: Handler? {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return handlerStorage
        }
        set {
            stateLock.lock()
            handlerStorage = newValue
            stateLock.unlock()
        }
    }

    static var didStart: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return didStartStorage
    }

    static var wasStopped: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return wasStoppedStorage
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.recordStart()
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        work = Task {
            do {
                let (response, data) = try await handler(request)
                guard !Task.isCancelled else { return }
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                guard !Task.isCancelled else { return }
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {
        Self.recordStop()
        work?.cancel()
    }

    static func reset() {
        stateLock.lock()
        handlerStorage = nil
        didStartStorage = false
        wasStoppedStorage = false
        stateLock.unlock()
    }

    private static func recordStart() {
        stateLock.lock()
        didStartStorage = true
        stateLock.unlock()
    }

    private static func recordStop() {
        stateLock.lock()
        wasStoppedStorage = true
        stateLock.unlock()
    }

    static func reply(
        request: URLRequest,
        status: Int = 200,
        headers: [String: String] = [:],
        body: String
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        return (response, Data(body.utf8))
    }
}
