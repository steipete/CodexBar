import Foundation

/// Shared OpenCode web protocol parsing. Callers retain their own quota encodings and required lanes.
enum OpenCodeWebParsing {
    typealias WindowParser = ([String: Any]) -> (percent: Double, resetInSec: Int)?

    static func normalizeWorkspaceID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("wrk_"), trimmed.count > 4 {
            return trimmed
        }
        if let url = URL(string: trimmed) {
            let parts = url.pathComponents
            if let index = parts.firstIndex(of: "workspace"),
               parts.count > index + 1
            {
                let candidate = parts[index + 1]
                if candidate.hasPrefix("wrk_"), candidate.count > 4 {
                    return candidate
                }
            }
        }
        if let match = trimmed.range(of: #"wrk_[A-Za-z0-9]+"#, options: .regularExpression) {
            return String(trimmed[match])
        }
        return nil
    }

    static func parseWorkspaceIDs(text: String) -> [String] {
        let pattern = #"id\s*:\s*\"(wrk_[^\"]+)\""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let nsrange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: nsrange).compactMap { match in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
    }

    static func parseWorkspaceIDsFromJSON(text: String) -> [String] {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [])
        else {
            return []
        }
        var results: [String] = []
        self.collectWorkspaceIDs(object: object, out: &results)
        return results
    }

    private static func collectWorkspaceIDs(object: Any, out: inout [String]) {
        if let dict = object as? [String: Any] {
            for (_, value) in dict {
                self.collectWorkspaceIDs(object: value, out: &out)
            }
            return
        }
        if let array = object as? [Any] {
            for value in array {
                self.collectWorkspaceIDs(object: value, out: &out)
            }
            return
        }
        if let string = object as? String,
           string.hasPrefix("wrk_"),
           !out.contains(string)
        {
            out.append(string)
        }
    }

    static func extractDouble(pattern: String, text: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let nsrange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsrange),
              let range = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return Double(text[range])
    }

    static func extractInt(pattern: String, text: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let nsrange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsrange),
              let range = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return Int(text[range])
    }

    static func value(from dict: [String: Any], keys: [String]) -> Any? {
        for key in keys {
            if let value = dict[key] {
                return value
            }
        }
        return nil
    }

    static func resetInterval(from resetAt: Date, now: Date) -> Int? {
        let interval = resetAt.timeIntervalSince(now)
        guard interval.isFinite else { return nil }
        if interval <= 0 { return 0 }
        guard interval < Double(Int.max) else { return nil }
        return Int(interval)
    }

    struct WindowCandidate {
        let id: UUID
        let percent: Double
        let resetInSec: Int
        let pathLower: String
    }

    static func collectWindowCandidates(object: Any, parseWindow: WindowParser) -> [WindowCandidate] {
        var candidates: [WindowCandidate] = []
        self.collectWindowCandidates(object: object, parseWindow: parseWindow, path: [], out: &candidates)
        return candidates
    }

    static func collectWindowCandidates(
        object: Any,
        parseWindow: WindowParser,
        path: [String],
        out: inout [WindowCandidate])
    {
        if let dict = object as? [String: Any] {
            if let window = parseWindow(dict) {
                let pathLower = path.joined(separator: ".").lowercased()
                out.append(WindowCandidate(
                    id: UUID(),
                    percent: window.percent,
                    resetInSec: window.resetInSec,
                    pathLower: pathLower))
            }
            for (key, value) in dict {
                self.collectWindowCandidates(object: value, parseWindow: parseWindow, path: path + [key], out: &out)
            }
            return
        }

        if let array = object as? [Any] {
            for (index, value) in array.enumerated() {
                self.collectWindowCandidates(
                    object: value,
                    parseWindow: parseWindow,
                    path: path + ["[\(index)]"],
                    out: &out)
            }
        }
    }

    static func pickCandidate(
        preferred: [WindowCandidate],
        fallback: [WindowCandidate],
        pickShorter: Bool,
        excluding excluded: UUID? = nil) -> WindowCandidate?
    {
        let filteredPreferred = preferred.filter { $0.id != excluded }
        if let picked = self.pickCandidate(from: filteredPreferred, pickShorter: pickShorter) {
            return picked
        }
        let filteredFallback = fallback.filter { $0.id != excluded }
        return self.pickCandidate(from: filteredFallback, pickShorter: pickShorter)
    }

    static func pickCandidate(from candidates: [WindowCandidate], pickShorter: Bool) -> WindowCandidate? {
        guard !candidates.isEmpty else { return nil }
        let comparator: (WindowCandidate, WindowCandidate) -> Bool = { lhs, rhs in
            if pickShorter {
                if lhs.resetInSec == rhs.resetInSec { return lhs.percent > rhs.percent }
                return lhs.resetInSec < rhs.resetInSec
            }
            if lhs.resetInSec == rhs.resetInSec { return lhs.percent > rhs.percent }
            return lhs.resetInSec > rhs.resetInSec
        }
        return candidates.min(by: comparator)
    }
}
