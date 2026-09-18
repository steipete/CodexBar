import Foundation

enum AppVersion {
    static var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    static var buildNumber: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    static var displayString: String {
        let version = self.shortVersion.isEmpty ? "–" : self.shortVersion
        return self.buildNumber.map { "\(version) (\($0))" } ?? version
    }
}
