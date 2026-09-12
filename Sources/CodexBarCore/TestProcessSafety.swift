import Foundation

package enum TestProcessSafety {
    package static var isRunning: Bool {
        if self.isRunningUnderTests(
            hasLoadedXCTestCase: NSClassFromString("XCTestCase") != nil,
            arguments: CommandLine.arguments)
        {
            return true
        }
        #if os(macOS)
        return Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") }
        #else
        // Enumerating Bundle.allBundles can crash swift-corelibs-foundation.
        return Bundle.main.executableURL?.path.hasSuffix(".xctest") ?? false
        #endif
    }

    package static func isRunningUnderTests(
        processName: String = ProcessInfo.processInfo.processName,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        hasLoadedXCTestCase: Bool = false,
        arguments: [String] = []) -> Bool
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
            || arguments.contains {
                let argument = $0.lowercased()
                return argument.contains("xctest") || argument.contains("swift-testing")
            }
    }
}
