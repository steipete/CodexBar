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
            || self.isTestExecutable(processName)
            || environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
            || environment["TESTING_LIBRARY_VERSION"] != nil
            || environment["SWIFT_TESTING"] != nil
            || environment["SWIFT_TESTING_ENABLED"] != nil
            || arguments.first.map(self.isTestExecutable) == true
    }

    private static func isTestExecutable(_ path: String) -> Bool {
        // Only the executable identifies a runner; account values and parent directories may contain these words.
        let name = (path as NSString).lastPathComponent.lowercased()
        return ["xctest", "xctestrunner", "swift-testing", "swiftpm-testing-helper"].contains(name)
            || name.hasSuffix("packagetests")
            || name.hasSuffix(".xctest")
    }
}
