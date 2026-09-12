import Testing
@testable import CodexBarCore

struct TestProcessSafetyTests {
    @Test(arguments: [
        ("swiftpm-testing-helper", [:]),
        ("CodexBarPackageTests", [:]),
        ("CodexBarPackageTests.xctest", [:]),
        ("CodexBar", ["XCTestConfigurationFilePath": "fixture"]),
        ("CodexBar", ["XCTestBundlePath": "fixture"]),
        ("CodexBar", ["XCTestSessionIdentifier": "fixture"]),
        ("CodexBar", ["TESTING_LIBRARY_VERSION": "fixture"]),
        ("CodexBar", ["SWIFT_TESTING": "fixture"]),
        ("CodexBar", ["SWIFT_TESTING_ENABLED": "fixture"]),
    ] as [(String, [String: String])])
    func `recognizes every supported runner signal`(
        processName: String,
        environment: [String: String])
    {
        #expect(TestProcessSafety.isRunningUnderTests(
            processName: processName,
            environment: environment))
    }

    @Test
    func `recognizes the loaded XCTest fallback without class lookup side effects`() {
        #expect(TestProcessSafety.isRunningUnderTests(
            processName: "CodexBar",
            environment: [:],
            hasLoadedXCTestCase: true))
    }

    @Test
    func `does not classify an ordinary app process as a test runner`() {
        #expect(!TestProcessSafety.isRunningUnderTests(
            processName: "CodexBar",
            environment: [:]))
    }
}
