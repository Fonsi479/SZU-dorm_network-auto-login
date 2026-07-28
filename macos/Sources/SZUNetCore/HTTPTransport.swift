import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPResponse {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data
    public var finalURL: URL

    public init(statusCode: Int, headers: [String: String], body: Data, finalURL: URL) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.finalURL = finalURL
    }

    public var bodyText: String {
        if let value = String(data: body, encoding: .utf8) {
            return value
        }
        let encoding = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
        )
        return String(data: body, encoding: encoding) ?? String(decoding: body, as: UTF8.self)
    }
}

public protocol HTTPTransporting: AnyObject {
    func get(
        _ url: URL,
        query: [String: String],
        headers: [String: String],
        timeout: TimeInterval,
        sourceIP: String?
    ) async throws -> HTTPResponse
}

/// A long-lived, cancellation-aware HTTP session.
///
/// The old implementation created a new ephemeral URLSession for every request
/// and sent portal HTTP through a separate raw-socket parser. That discarded the
/// portal's cookie/session state and made Task cancellation ineffective. Keeping
/// one URLSession per transport fixes both without mixing routing and HTTP duties.
public final class URLSessionHTTPTransport: HTTPTransporting {
    public static let portalShared = URLSessionHTTPTransport()

    private let redirectDelegate: RedirectBlockingDelegate
    private let cookieStorage: HTTPCookieStorage?
    private let session: URLSession
    private let sourceBoundTransport = SourceBoundHTTPTransport()

    public init(configuration suppliedConfiguration: URLSessionConfiguration? = nil) {
        let configuration = suppliedConfiguration ?? URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        configuration.connectionProxyDictionary = [:]

        let delegate = RedirectBlockingDelegate()
        redirectDelegate = delegate
        cookieStorage = configuration.httpCookieStorage
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    public func get(
        _ url: URL,
        query: [String: String] = [:],
        headers: [String: String] = [:],
        timeout: TimeInterval,
        sourceIP: String? = nil
    ) async throws -> HTTPResponse {
        try Task.checkCancellation()
        let requestURL = try URLQueryBuilder.appending(query, to: url)
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        if request.value(forHTTPHeaderField: "Cookie") == nil,
           let cookies = cookieStorage?.cookies(for: requestURL),
           !cookies.isEmpty {
            HTTPCookie.requestHeaderFields(with: cookies).forEach {
                request.setValue($0.value, forHTTPHeaderField: $0.key)
            }
        }

        if let requiredSourceIP = sourceIP?.trimmingCharacters(in: .whitespacesAndNewlines),
           !requiredSourceIP.isEmpty {
            let response = try await sourceBoundTransport.execute(
                request,
                sourceIP: requiredSourceIP,
                timeout: timeout
            )
            storeCookies(from: response, requestURL: requestURL)
            return response
        }

        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let httpResponse = response as? HTTPURLResponse else {
                throw SZUNetError.network("服务器没有返回 HTTP 响应。")
            }
            let normalizedHeaders = httpResponse.allHeaderFields.reduce(into: [String: String]()) {
                $0[String(describing: $1.key).lowercased()] = String(describing: $1.value)
            }
            let result = HTTPResponse(
                statusCode: httpResponse.statusCode,
                headers: normalizedHeaders,
                body: data,
                finalURL: httpResponse.url ?? requestURL
            )
            storeCookies(from: result, requestURL: requestURL)
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SZUNetError {
            throw error
        } catch {
            throw SZUNetError.network(Self.describe(error))
        }
    }

    private func storeCookies(from response: HTTPResponse, requestURL: URL) {
        guard let setCookie = response.headers["set-cookie"] else { return }
        let cookies = HTTPCookie.cookies(
            withResponseHeaderFields: ["Set-Cookie": setCookie],
            for: response.finalURL
        )
        cookieStorage?.setCookies(cookies, for: response.finalURL, mainDocumentURL: requestURL)
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        switch nsError.code {
        case NSURLErrorCancelled:
            return "cancelled"
        case NSURLErrorTimedOut:
            return "timeout"
        case NSURLErrorCannotConnectToHost,
             NSURLErrorCannotFindHost,
             NSURLErrorDNSLookupFailed,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorNotConnectedToInternet:
            return "connection_failed"
        default:
            return nsError.localizedDescription
        }
    }
}

/// Portal clients share one in-memory cookie jar for the app lifetime. General
/// connectivity probes instantiate their own URLSessionHTTPTransport instead.
public final class PortalHTTPTransport: HTTPTransporting {
    private let transport: HTTPTransporting

    public init(urlSessionTransport: HTTPTransporting = URLSessionHTTPTransport.portalShared) {
        transport = urlSessionTransport
    }

    public func get(
        _ url: URL,
        query: [String: String] = [:],
        headers: [String: String] = [:],
        timeout: TimeInterval,
        sourceIP: String? = nil
    ) async throws -> HTTPResponse {
        try await transport.get(
            url,
            query: query,
            headers: headers,
            timeout: timeout,
            sourceIP: sourceIP
        )
    }
}

private final class RedirectBlockingDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
