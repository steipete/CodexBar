import Foundation

enum SettingsSearch {
    static func words(in query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Every query word must appear in at least one field, ignoring case and diacritics.
    static func matches(words: [String], fields: [String]) -> Bool {
        words.allSatisfy { word in
            fields.contains { $0.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    /// App panes whose title matches the query; an empty query keeps them all.
    static func filteredPanes(_ panes: [SettingsPane], query: String) -> [SettingsPane] {
        let words = self.words(in: query)
        guard !words.isEmpty else { return panes }
        return panes.filter { self.matches(words: words, fields: [$0.title]) }
    }
}
