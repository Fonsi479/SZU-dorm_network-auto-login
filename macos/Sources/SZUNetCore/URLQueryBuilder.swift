import Foundation

public enum URLQueryBuilder {
    public static func appending(_ query: [String: String], to url: URL) throws -> URL {
        guard !query.isEmpty else { return url }
        let queryText = query
            .sorted { $0.key < $1.key }
            .map { "\(percentEncode($0.key))=\(percentEncode($0.value))" }
            .joined(separator: "&")
        let separator = url.absoluteString.contains("?") ? "&" : "?"
        guard let result = URL(string: url.absoluteString + separator + queryText) else {
            throw SZUNetError.network("无法构造 HTTP 请求地址。")
        }
        return result
    }

    public static func percentEncode(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}
