import Foundation
import Testing
@testable import CodexBarCore

struct OpenCodeWebParsingTests {
    @Test
    func `numeric fields preserve priority and skip invalid values`() {
        #expect(OpenCodeWebParsing.doubleValue(from: " 0.5\n") == 0.5)
        #expect(OpenCodeWebParsing.doubleValue(from: Double.infinity) == nil)
        #expect(OpenCodeWebParsing.doubleValue(from: "NaN") == nil)
        #expect(OpenCodeWebParsing.doubleValue(from: NSNull()) == nil)
        #expect(OpenCodeWebParsing.doubleValue(
            from: ["usagePercent": "invalid", "percent": 0.5, "usage": 90],
            keys: OpenCodeWebParsing.percentKeys) == 0.5)
        #expect(OpenCodeWebParsing.intValue(
            from: ["resetInSec": "invalid", "resetSeconds": " 42 "],
            keys: OpenCodeWebParsing.resetInKeys) == 42)
        #expect(OpenCodeWebParsing.intValue(from: NSNumber(value: 4.5)) == 4)
        #expect(OpenCodeWebParsing.intValue(from: "4.5") == nil)
    }

    @Test
    func `dates preserve epoch thresholds and fractional ISO parsing`() {
        let expected = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(OpenCodeWebParsing.dateValue(from: 1_800_000_000) == expected)
        #expect(OpenCodeWebParsing.dateValue(from: " 1800000000000 ") == expected)
        #expect(OpenCodeWebParsing.dateValue(from: 1_000_000_000) == nil)
        #expect(OpenCodeWebParsing.dateValue(from: 1_000_000_000_000) ==
            Date(timeIntervalSince1970: 1_000_000_000_000))
        #expect(OpenCodeWebParsing.dateValue(from: "2027-01-15T08:00:00.000Z") == expected)
        #expect(OpenCodeWebParsing.dateValue(from: "invalid") == nil)
        #expect(OpenCodeWebParsing.dateValue(from: Double.infinity) == nil)
    }

    @Test
    func `server errors retain JSON field precedence and HTML fallback`() {
        #expect(OpenCodeWebParsing.extractServerErrorMessage(
            from: #"{"message":"first","error":"second","detail":"third"}"#) == "first")
        #expect(OpenCodeWebParsing.extractServerErrorMessage(
            from: #"{"message":"","error":"second","detail":"third"}"#) == "second")
        #expect(OpenCodeWebParsing.extractServerErrorMessage(from: #"{"detail":"third"}"#) == "third")
        #expect(OpenCodeWebParsing.extractServerErrorMessage(from: "<TITLE> Retry later </TITLE>") == "Retry later")
        #expect(OpenCodeWebParsing.extractServerErrorMessage(from: #"["error"]"#) == nil)
        #expect(OpenCodeWebParsing.extractServerErrorMessage(from: "plain text") == nil)
    }

    @Test(arguments: [
        "LOGIN",
        "Sign In",
        "auth/authorize",
        "not associated with an account",
        "Actor of type \"public\""
    ])
    func `legacy signed out markers are case insensitive`(text: String) {
        #expect(OpenCodeWebParsing.looksSignedOut(text: text))
        #expect(!OpenCodeWebParsing.looksSignedOut(text: #"{"usagePercent":50}"#))
    }
}
