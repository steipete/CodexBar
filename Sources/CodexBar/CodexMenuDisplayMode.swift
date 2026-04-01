import Foundation

enum CodexMenuDisplayMode: String, Sendable {
    case single
    case all

    static let `default`: Self = .single
}
