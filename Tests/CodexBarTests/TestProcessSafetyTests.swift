import Testing
@testable import CodexBarCore

struct TestProcessSafetyTests {
    @Test
    func `current process is recognized without callers supplying runner signals`() {
        #expect(TestProcessSafety.isRunning)
    }

    @Test(arguments: [["/tmp/Suite.xctest"], ["swift-testing"], ["/tmp/XCTestRunner"]])
    func `recognizes runner executable arguments`(arguments: [String]) {
        #expect(TestProcessSafety.isRunningUnderTests(
            processName: "runner",
            environment: [:],
            arguments: arguments))
    }

    @Test(arguments: [
        ["/usr/local/bin/codexbar", "--account", "swift-testing"],
        ["/usr/local/bin/codexbar", "--account", "xctest"],
        ["/usr/local/bin/codexbar", "--account", "Example.xctest"],
        ["/tmp/swift-testing/codexbar", "usage"],
        ["/tmp/Example.xctest/codexbar", "usage"],
        ["/tmp/XCTestRunnerTools/codexbar", "usage"],
    ])
    func `ordinary argument values and installation paths retain production behavior`(arguments: [String]) {
        #expect(!TestProcessSafety.isRunningUnderTests(
            processName: "codexbar",
            environment: [:],
            arguments: arguments))
    }

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
