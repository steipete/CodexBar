import AppKit
import Foundation

struct NotificationDeliverySettings: Equatable, Sendable {
    var enabled: Bool
    var sound: NotificationSoundOption
    var hookCallURL: String
    var shortcutName: String

    static let localDefault = NotificationDeliverySettings(
        enabled: true,
        sound: .systemDefault,
        hookCallURL: "",
        shortcutName: "")

    var normalized: NotificationDeliverySettings {
        NotificationDeliverySettings(
            enabled: self.enabled,
            sound: self.sound,
            hookCallURL: self.hookCallURL.trimmingCharacters(in: .whitespacesAndNewlines),
            shortcutName: self.shortcutName.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

enum NotificationSoundOption: String, CaseIterable, Identifiable, Sendable {
    case none
    case systemDefault
    case basso
    case blow
    case bottle
    case frog
    case funk
    case glass
    case hero
    case morse
    case ping
    case pop
    case purr
    case sosumi
    case submarine
    case tink

    var id: String {
        self.rawValue
    }

    var label: String {
        switch self {
        case .none:
            "None"
        case .systemDefault:
            "System Default"
        case .basso:
            "Basso"
        case .blow:
            "Blow"
        case .bottle:
            "Bottle"
        case .frog:
            "Frog"
        case .funk:
            "Funk"
        case .glass:
            "Glass"
        case .hero:
            "Hero"
        case .morse:
            "Morse"
        case .ping:
            "Ping"
        case .pop:
            "Pop"
        case .purr:
            "Purr"
        case .sosumi:
            "Sosumi"
        case .submarine:
            "Submarine"
        case .tink:
            "Tink"
        }
    }

    var systemSoundName: String? {
        switch self {
        case .none, .systemDefault:
            nil
        case .basso:
            "Basso"
        case .blow:
            "Blow"
        case .bottle:
            "Bottle"
        case .frog:
            "Frog"
        case .funk:
            "Funk"
        case .glass:
            "Glass"
        case .hero:
            "Hero"
        case .morse:
            "Morse"
        case .ping:
            "Ping"
        case .pop:
            "Pop"
        case .purr:
            "Purr"
        case .sosumi:
            "Sosumi"
        case .submarine:
            "Submarine"
        case .tink:
            "Tink"
        }
    }
}

@MainActor
enum NotificationSoundPlayer {
    @discardableResult
    static func playPreview(_ sound: NotificationSoundOption, volume: Double) -> Bool {
        switch sound {
        case .none:
            return false
        case .systemDefault:
            NSSound.beep()
            return true
        default:
            return self.play(sound, volume: volume)
        }
    }

    @discardableResult
    static func play(_ sound: NotificationSoundOption, volume: Double = 1.0) -> Bool {
        guard let name = sound.systemSoundName else { return false }
        guard let sound = NSSound(named: NSSound.Name(name)) else { return false }
        sound.stop()
        sound.volume = Float(min(max(volume, 0.0), 1.0))
        return sound.play()
    }
}

enum AppNotificationEvent: String, CaseIterable, Identifiable, Sendable {
    case sessionQuotaDepleted
    case sessionQuotaRestored
    case providerLogin
    case augmentSessionExpired

    var id: String {
        self.rawValue
    }

    var settingsTitle: String {
        switch self {
        case .sessionQuotaDepleted:
            "Session quota depleted"
        case .sessionQuotaRestored:
            "Session quota restored"
        case .providerLogin:
            "Provider login successful"
        case .augmentSessionExpired:
            "Augment session expired"
        }
    }

    var settingsSubtitle: String {
        switch self {
        case .sessionQuotaDepleted:
            "When a tracked provider hits 0% remaining in the current 5-hour session."
        case .sessionQuotaRestored:
            "When a tracked provider becomes available again after a depleted session."
        case .providerLogin:
            "After a provider login flow launched from CodexBar completes successfully."
        case .augmentSessionExpired:
            "When Augment recovery still needs a manual browser login."
        }
    }

    var hookPlaceholder: String {
        switch self {
        case .sessionQuotaDepleted:
            "https://example.com/hooks/session-depleted"
        case .sessionQuotaRestored:
            "https://example.com/hooks/session-restored"
        case .providerLogin:
            "https://example.com/hooks/provider-login"
        case .augmentSessionExpired:
            "https://example.com/hooks/augment-expired"
        }
    }

    var recommendedShortcutName: String {
        switch self {
        case .sessionQuotaDepleted:
            "CodexBar Session Quota Depleted"
        case .sessionQuotaRestored:
            "CodexBar Session Quota Restored"
        case .providerLogin:
            "CodexBar Provider Login"
        case .augmentSessionExpired:
            "CodexBar Augment Session Expired"
        }
    }

    var shortcutPlaceholder: String {
        self.recommendedShortcutName
    }

    var defaultSound: NotificationSoundOption {
        switch self {
        case .sessionQuotaDepleted:
            .basso
        case .sessionQuotaRestored:
            .glass
        case .providerLogin:
            .hero
        case .augmentSessionExpired:
            .submarine
        }
    }

    var defaultSettings: NotificationDeliverySettings {
        NotificationDeliverySettings(
            enabled: true,
            sound: self.defaultSound,
            hookCallURL: "",
            shortcutName: "")
    }

    var enabledDefaultsKey: String {
        "notification.\(self.rawValue).enabled"
    }

    var soundDefaultsKey: String {
        "notification.\(self.rawValue).sound"
    }

    var hookCallURLDefaultsKey: String {
        "notification.\(self.rawValue).hookCallURL"
    }

    var shortcutNameDefaultsKey: String {
        "notification.\(self.rawValue).shortcutName"
    }
}
