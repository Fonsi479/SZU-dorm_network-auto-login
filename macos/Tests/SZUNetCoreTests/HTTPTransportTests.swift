import Foundation
import Testing
@testable import SZUNetCore

@Suite("HTTP transport", .serialized)
struct HTTPTransportTests {
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
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("cancelled transport unexpectedly returned a response")
        } catch is CancellationError {
            // Expected.
        } catch {
            #expect(error.localizedDescription.contains("cancelled"))
        }
        #expect(MockURLProtocol.wasStopped)
    }
}

private final class MockURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) async throws -> (HTTPURLResponse, Data)

    static var handler: Handler?
    static var wasStopped = false
    private var work: Task<Void, Never>?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
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
        Self.wasStopped = true
        work?.cancel()
    }

    static func reset() {
        handler = nil
        wasStopped = false
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
