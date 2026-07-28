import Foundation
import Testing
@testable import SZUNetCore

@Suite("SRun BX1 vectors")
struct SRunCryptoTests {
    @Test("Swift consumes the shared base64 and xencode vectors")
    func sharedCrossChecks() throws {
        let vector = try loadVector()

        #expect(SRunCrypto.customBase64(Data(vector.crossChecks.base64.inputUtf8.utf8))
            == vector.crossChecks.base64.expected)
        #expect(SRunCrypto.xencode(
            message: vector.crossChecks.xencode.messageUtf8,
            key: vector.crossChecks.xencode.keyUtf8
        ).hex == vector.crossChecks.xencode.expectedHex)
    }

    @Test("complete synthetic login vector matches all derived fields")
    func completeLoginVector() throws {
        let vector = try loadVector().fullLoginVector
        let fields = SRunCrypto.deriveLoginFields(
            username: vector.username,
            password: vector.credentialInput,
            clientIP: vector.clientIP,
            acid: vector.acid,
            challenge: vector.challenge,
            n: vector.n,
            type: vector.type
        )

        #expect(fields.infoJSON == vector.expectedInfoJSON)
        #expect(fields.hmacMD5Hex == vector.expectedHMACMD5Hex)
        #expect(fields.passwordField == vector.expectedPasswordField)
        #expect(fields.infoField == vector.expectedInfoField)
        #expect(fields.checksum == vector.expectedChecksum)
    }

    private func loadVector() throws -> SRunVector {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("protocol-spec/vectors/srun-bx1.json")
        return try JSONDecoder().decode(SRunVector.self, from: Data(contentsOf: url))
    }
}

private struct SRunVector: Decodable {
    struct CrossChecks: Decodable {
        struct Base64: Decodable { let inputUtf8: String; let expected: String }
        struct XEncode: Decodable { let messageUtf8: String; let keyUtf8: String; let expectedHex: String }
        let base64: Base64
        let xencode: XEncode
    }
    struct Login: Decodable {
        let username: String
        let credentialInput: String
        let clientIP: String
        let acid: String
        let challenge: String
        let n: String
        let type: String
        let expectedInfoJSON: String
        let expectedHMACMD5Hex: String
        let expectedPasswordField: String
        let expectedInfoField: String
        let expectedChecksum: String
    }
    let crossChecks: CrossChecks
    let fullLoginVector: Login
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
