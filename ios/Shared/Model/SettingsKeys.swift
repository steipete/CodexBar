import Foundation

/// UserDefaults keys stored in the shared App Group suite so the app and its extensions agree.
public enum SettingsKeys {
    public static let lanEnabled = "sync.lanEnabled"
    public static let iCloudEnabled = "sync.iCloudEnabled"
    /// Live Activities are OFF by default (opt-in), per product requirement.
    public static let liveActivitiesEnabled = "liveActivities.enabled"
}
