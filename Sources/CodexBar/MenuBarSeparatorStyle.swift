import Foundation

/// Controls the separator character between percent and pace in the menu bar.
enum MenuBarSeparatorStyle: String, CaseIterable, Identifiable {
    case dot
    case pipe

    var id: String {
        self.rawValue
    }

    var separator: String {
        switch self {
        case .dot: " · "
        case .pipe: " | "
        }
    }

    var label: String {
        switch self {
        case .dot: "Dot (·)"
        case .pipe: "Pipe (|)"
        }
    }
}
