import CodexBarCore
import ServiceManagement

enum LaunchAtLoginManager {
    typealias StatusProvider = () -> SMAppService.Status
    typealias RegistrationAction = () throws -> Void

    private static let isRunningTests: Bool = {
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil { return true }
        if env["TESTING_LIBRARY_VERSION"] != nil { return true }
        if env["SWIFT_TESTING"] != nil { return true }
        return NSClassFromString("XCTestCase") != nil
    }()

    static func setEnabled(_ enabled: Bool) {
        if self.isRunningTests { return }
        let service = SMAppService.mainApp
        self.setEnabled(
            enabled,
            status: { service.status },
            register: { try service.register() },
            unregister: { try service.unregister() })
    }

    static func setEnabled(
        _ enabled: Bool,
        status: StatusProvider,
        register: RegistrationAction,
        unregister: RegistrationAction)
    {
        do {
            if enabled {
                switch status() {
                case .enabled, .requiresApproval:
                    return
                case .notRegistered, .notFound:
                    try register()
                @unknown default:
                    try register()
                }
            } else {
                switch status() {
                case .enabled, .requiresApproval:
                    try unregister()
                case .notRegistered, .notFound:
                    return
                @unknown default:
                    try unregister()
                }
            }
        } catch {
            CodexBarLog.logger(LogCategories.launchAtLogin).error("Failed to update login item: \(error)")
        }
    }
}
