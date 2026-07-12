import Foundation
import Testing
@testable import SZUNetCore

@Suite("URL query encoding")
struct URLQueryBuilderTests {
    @Test("credentials are RFC3986 encoded exactly once")
    func encodesCredentialsExactlyOnce() throws {
        let url = try #require(URL(string: "http://172.30.255.42/login?existing=1"))
        let result = try URLQueryBuilder.appending(
            [
                "user_account": ",1,学号",
                "user_password": "p&a ss/中文",
            ],
            to: url
        ).absoluteString

        #expect(result.contains("existing=1&"))
        #expect(result.contains("user_account=%2C1%2C%E5%AD%A6%E5%8F%B7"))
        #expect(result.contains("user_password=p%26a%20ss%2F%E4%B8%AD%E6%96%87"))
        #expect(!result.contains("%252C"), "query values must not be double encoded")
    }

    @Test("an empty query preserves the original URL")
    func emptyQueryKeepsOriginalURL() throws {
        let url = try #require(URL(string: "http://172.30.255.42/a79.htm#fragment"))
        #expect(try URLQueryBuilder.appending([:], to: url) == url)
    }
}
