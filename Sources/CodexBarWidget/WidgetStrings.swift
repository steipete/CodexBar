import Foundation

enum WidgetStrings {
    private static let table = "Localizable"

    static func tr(_ key: String) -> String {
        Bundle.module.localizedString(forKey: key, value: key, table: self.table)
    }

    static func resource(_ key: String) -> LocalizedStringResource {
        LocalizedStringResource(stringLiteral: self.tr(key))
    }

    static func fmt(_ key: String, _ args: CVarArg...) -> String {
        String(format: self.tr(key), locale: .current, arguments: args)
    }
}
