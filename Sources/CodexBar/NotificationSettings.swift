import AppKit
import Foundation

struct NotificationDeliverySettings: Equatable, Sendable {
    var enabled: Bool
    var sound: NotificationSoundOption

    static let localDefault = NotificationDeliverySettings(
        enabled: true,
        sound: .systemDefault)
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
}
