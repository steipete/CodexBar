import Foundation

enum CodexPriorityDatabasePath {
    private static let testDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("codexbar-cost-trace-tests-\(UUID().uuidString)", isDirectory: true)

    static func defaultURL(
        processName: String = ProcessInfo.processInfo.processName,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        codexHome: (() -> URL)? = nil) -> URL
    {
        // Session-root fixtures do not select a trace database; isolate the fallback before consulting user paths.
        let directory = if CodexCredentialFileAccess.isTestContext(processName: processName, environment: environment) {
            self.testDirectory
        } else {
            codexHome?() ?? CodexHomeScope.ambientHomeURL(env: environment)
        }
        return self.databaseURL(forCodexHome: directory)
    }

    static func databaseURL(forCodexHome codexHome: URL) -> URL {
        codexHome.appendingPathComponent("logs_2.sqlite", isDirectory: false)
    }
}
