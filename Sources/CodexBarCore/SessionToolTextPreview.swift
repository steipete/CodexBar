import Foundation

enum SessionToolTextPreview {
    /// Character limits alone do not bound a grapheme with thousands of combining scalars.
    static func prefix(_ text: String, characters: Int, bytes: Int) -> String {
        let prefix = Array(text.utf8.prefix(bytes))
        var end = prefix.count
        while end > 0 {
            if let decoded = String(bytes: prefix[..<end], encoding: .utf8) {
                return String(decoded.prefix(characters))
            }
            end -= 1
        }
        return ""
    }
}
