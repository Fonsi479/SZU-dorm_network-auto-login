import Darwin
import Foundation

public struct SourceRoute: Equatable {
    public var reachable: Bool
    public var sourceIP: String
    public var reason: String

    public init(reachable: Bool, sourceIP: String = "", reason: String = "") {
        self.reachable = reachable
        self.sourceIP = sourceIP
        self.reason = reason
    }
}

public protocol SourceRouteResolving: AnyObject {
    func resolve(host: String, port: UInt16, timeout: TimeInterval) -> SourceRoute
}

public final class SourceRouteResolver: SourceRouteResolving {
    public init() {}

    public func resolve(host: String, port: UInt16, timeout: TimeInterval) -> SourceRoute {
        do {
            let descriptor = try Self.connect(host: host, port: port, timeout: timeout)
            defer { Darwin.close(descriptor) }
            return SourceRoute(reachable: true, sourceIP: try Self.sourceAddress(descriptor))
        } catch {
            return SourceRoute(reachable: false, reason: Self.shortDescription(error))
        }
    }

    public func sourceAddress(host: String, port: UInt16, timeout: TimeInterval) throws -> String {
        let descriptor = try Self.connect(host: host, port: port, timeout: timeout)
        defer { Darwin.close(descriptor) }
        return try Self.sourceAddress(descriptor)
    }

    private static func connect(host: String, port: UInt16, timeout: TimeInterval) throws -> Int32 {
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_INET,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &result)
        guard status == 0, let first = result else {
            throw SZUNetError.network("DNS 解析失败：\(String(cString: gai_strerror(status)))")
        }
        defer { freeaddrinfo(result) }

        var lastError: Error = SZUNetError.network("connection_failed")
        var current: UnsafeMutablePointer<addrinfo>? = first
        while let address = current {
            current = address.pointee.ai_next
            let descriptor = socket(
                address.pointee.ai_family,
                address.pointee.ai_socktype,
                address.pointee.ai_protocol
            )
            guard descriptor >= 0 else { continue }
            do {
                try connectNonBlocking(
                    descriptor,
                    address: address.pointee.ai_addr,
                    length: address.pointee.ai_addrlen,
                    timeout: timeout
                )
                return descriptor
            } catch {
                lastError = error
                Darwin.close(descriptor)
            }
        }
        throw lastError
    }

    private static func connectNonBlocking(
        _ descriptor: Int32,
        address: UnsafeMutablePointer<sockaddr>?,
        length: socklen_t,
        timeout: TimeInterval
    ) throws {
        guard let address else { throw SZUNetError.network("目标地址为空。") }
        let oldFlags = fcntl(descriptor, F_GETFL, 0)
        guard oldFlags >= 0, fcntl(descriptor, F_SETFL, oldFlags | O_NONBLOCK) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer { _ = fcntl(descriptor, F_SETFL, oldFlags) }

        let result = Darwin.connect(descriptor, address, length)
        if result == 0 { return }
        guard errno == EINPROGRESS else {
            throw POSIXError(.init(rawValue: errno) ?? .ECONNREFUSED)
        }

        var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        let pollResult = Darwin.poll(&pollDescriptor, 1, Int32(max(1, timeout * 1_000)))
        guard pollResult > 0 else {
            if pollResult == 0 { throw SZUNetError.network("timeout") }
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        var socketError: Int32 = 0
        var errorLength = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &errorLength) == 0,
              socketError == 0 else {
            throw POSIXError(.init(rawValue: socketError == 0 ? errno : socketError) ?? .ECONNREFUSED)
        }
    }

    private static func sourceAddress(_ descriptor: Int32) throws -> String {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let status = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard status == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var copy = address.sin_addr
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &copy, &buffer, socklen_t(buffer.count)) != nil else {
            throw SZUNetError.network("source_ip_unavailable")
        }
        return String(cString: buffer)
    }

    private static func shortDescription(_ error: Error) -> String {
        if let error = error as? SZUNetError { return error.localizedDescription }
        return (error as NSError).localizedDescription
    }
}

/// Compatibility facade while callers migrate to SourceRouteResolver.
public enum SocketHTTPClient {
    private static let routeResolver = SourceRouteResolver()
    private static let compatibilityTransport = URLSessionHTTPTransport()

    public static func sourceAddress(host: String, port: UInt16, timeout: TimeInterval) throws -> String {
        try routeResolver.sourceAddress(host: host, port: port, timeout: timeout)
    }

    public static func canConnect(
        host: String,
        port: UInt16,
        timeout: TimeInterval
    ) -> (reachable: Bool, sourceIP: String, reason: String) {
        let result = routeResolver.resolve(host: host, port: port, timeout: timeout)
        return (result.reachable, result.sourceIP, result.reason)
    }

    public static func get(
        _ url: URL,
        query: [String: String],
        headers: [String: String],
        timeout: TimeInterval,
        sourceIP: String?
    ) async throws -> HTTPResponse {
        try await compatibilityTransport.get(
            url,
            query: query,
            headers: headers,
            timeout: timeout,
            sourceIP: sourceIP
        )
    }
}
