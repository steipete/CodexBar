import Foundation
import Testing
@testable import CodexBarCore

@Suite
struct MiniMaxLocalStorageImporterTests {
    @Test
    func extractsAccessTokensFromJSONPreferringLongTokens() {
        let shortToken = String(repeating: "b", count: 24)
        let longToken = String(repeating: "a", count: 72)
        let payload = """
        {"access_token":"\(shortToken)","nested":{"token":"\(longToken)"}}
        """

        let tokens = MiniMaxLocalStorageImporter._extractAccessTokensForTesting(payload)

        #expect(tokens.contains(longToken))
        #expect(tokens.contains(shortToken) == false)
    }

    @Test
    func extractsGroupIDFromJSONString() {
        let payload = """
        {"user":{"groupId":"98765"}}
        """

        let groupID = MiniMaxLocalStorageImporter._extractGroupIDForTesting(payload)

        #expect(groupID == "98765")
    }

    @Test
    func resolvesGroupIDFromJWTClaims() {
        let token = Self.makeJWT(payload: [
            "iss": "minimax",
            "group_id": "12345",
            "pad": String(repeating: "x", count: 80),
        ])

        #expect(MiniMaxLocalStorageImporter._isMiniMaxJWTForTesting(token))
        #expect(MiniMaxLocalStorageImporter._groupIDFromJWTForTesting(token) == "12345")
    }

    @Test
    func rejectsNonMiniMaxJWTsWithoutSignal() {
        let token = Self.makeJWT(payload: [
            "iss": "other",
            "pad": String(repeating: "y", count: 80),
        ])

        #expect(MiniMaxLocalStorageImporter._isMiniMaxJWTForTesting(token) == false)
    }

    private static func makeJWT(payload: [String: Any]) -> String {
        let header = ["alg": "none", "typ": "JWT"]
        let headerData = try? JSONSerialization.data(withJSONObject: header)
        let payloadData = try? JSONSerialization.data(withJSONObject: payload)
        let headerPart = self.base64URL(headerData ?? Data())
        let payloadPart = self.base64URL(payloadData ?? Data())
        let signature = String(repeating: "s", count: 32)
        return "\(headerPart).\(payloadPart).\(signature)"
    }

    private static func base64URL(_ data: Data) -> String {
        let raw = data.base64EncodedString()
        return raw
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
