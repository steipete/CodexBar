import Foundation

package enum TestProcessSafety {
    package static func isRunningUnderTests(
        processName: String = ProcessInfo.processInfo.processName,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        hasLoadedXCTestCase: Bool = false) -> Bool
    {
        hasLoadedXCTestCase
            || processName == "swiftpm-testing-helper"
            || processName.hasSuffix("PackageTests")
            || processName.hasSuffix(".xctest")
            || environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
            || environment["TESTING_LIBRARY_VERSION"] != nil
            || environment["SWIFT_TESTING"] != nil
            || environment["SWIFT_TESTING_ENABLED"] != nil
    }
}
