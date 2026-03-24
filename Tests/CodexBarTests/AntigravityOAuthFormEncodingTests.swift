import Foundation
import Testing
@testable import CodexBarCore

@Suite("AntigravityOAuthFormEncoding Tests")
struct AntigravityOAuthFormEncodingTests {
    @Test("bodyData percent-encodes reserved OAuth form values")
    func bodyDataEncodesReservedValues() throws {
        let body = AntigravityOAuthFormEncoding.bodyData([
            URLQueryItem(name: "code", value: "auth+code&next=value"),
            URLQueryItem(
                name: "redirect_uri",
                value: "http://127.0.0.1:8080/callback?state=alpha+beta&scope=a=b"),
        ])

        let bodyString = try #require(String(data: body, encoding: .utf8))

        #expect(bodyString.contains("code=auth%2Bcode%26next%3Dvalue"))
        #expect(
            bodyString.contains(
                "redirect_uri=http%3A%2F%2F127.0.0.1%3A8080%2Fcallback%3Fstate%3Dalpha%2Bbeta%26scope%3Da%3Db"))
    }
}
