import Foundation

enum AppVersion {
    static let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""

    static var displayString: String {
        let version = self.shortVersion.isEmpty ? "–" : self.shortVersion
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "\(version) (\($0))" } ?? version
    }
}
