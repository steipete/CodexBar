import Foundation

/// Menu-local shortcuts, expressed independently of AppKit and global hotkey registration.
public enum ProviderSwitcherShortcuts {
    public static let actions = ["previous", "next"] + (1...9).map { "select\($0)" }
    public static let defaults = Dictionary(uniqueKeysWithValues:
        zip(Self.actions, ["left", "right"] + (1...9).map { "cmd+\($0)" }))

    public static func validated(_ overrides: [String: String]) throws -> [String: String] {
        guard Set(overrides.keys).isSubset(of: Set(self.actions)) else {
            throw PreferencesDocument.Error.invalid("Unknown switcher action")
        }
        var result = self.defaults
        for (action, shortcut) in overrides {
            result[action] = try self.normalized(shortcut)
        }
        let assigned = result.values.filter { $0 != "none" }
        guard Set(assigned).count == assigned.count else {
            throw PreferencesDocument.Error.invalid("Switcher shortcuts must be unique")
        }
        return result
    }

    public static func normalized(_ shortcut: String) throws -> String {
        let parts = shortcut.lowercased().split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if parts == ["none"] { return "none" }
        let modifiers = ["ctrl", "alt", "shift", "cmd"]
        let supplied = Array(parts.dropLast())
        guard let key = parts.last,
              Set(supplied).count == supplied.count,
              supplied.allSatisfy(modifiers.contains),
              ["left", "right", ","].contains(key)
              || (key.count == 1 && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { throw PreferencesDocument.Error.invalid("Use a letter, digit, left or right with ctrl/alt/shift/cmd") }
        let result = (modifiers.filter(supplied.contains) + [key]).joined(separator: "+")
        guard !["cmd+r", "cmd+q", "cmd+,", "cmd+h", "cmd+m", "cmd+w", "alt+cmd+h"].contains(result),
              ["left", "right"].contains(key) || supplied.contains(where: { $0 != "shift" })
        else { throw PreferencesDocument.Error.invalid("That shortcut is reserved for a menu or system command") }
        return result
    }

    public static func action(key: String, modifiers: [String], mapping: [String: String]) -> String? {
        let combination = (modifiers + [key.lowercased()]).joined(separator: "+")
        return self.actions.first { mapping[$0] == combination }
    }
}
