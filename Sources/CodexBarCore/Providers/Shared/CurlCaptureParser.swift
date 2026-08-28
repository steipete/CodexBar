import Foundation

/// Shared parsing for "Copy as cURL" DevTools captures pasted by users into manual-auth provider
/// settings fields. Extracted from T3 Chat's original implementation (see #1830-era history) so
/// other web-cookie/bearer-token providers (e.g. ZoomMate) can reuse the exact same regex/shell
/// unescaping behavior instead of duplicating subtle parsing logic.
public enum CurlCaptureParser {
    /// Extracts the request URL from the standard DevTools "Copy as cURL" shape, where the URL is
    /// the first argument after `curl`. Returns `nil` for malformed captures or option-first forms.
    public static func requestURL(from raw: String) -> URL? {
        let pattern =
            #"(?s)(?:^|\s)curl\s+"# +
            #"(?:\$'((?:\\.|[^'])*)'|'([^']*)'|\"((?:\\.|[^\"])*)\"|([^\s\\]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        guard let match = regex.firstMatch(in: raw, options: [], range: range) else { return nil }

        let value: String? = if let ansi = self.capture(1, in: match, raw: raw) {
            self.unescapeShellSegment(ansi, ansi: true)
        } else if let single = self.capture(2, in: match, raw: raw) {
            single
        } else if let double = self.capture(3, in: match, raw: raw) {
            self.unescapeShellSegment(double, ansi: false)
        } else if let bare = self.capture(4, in: match, raw: raw) {
            self.unescapeShellSegment(bare, ansi: false)
        } else {
            nil
        }
        guard let value, !value.isEmpty else { return nil }
        guard let url = URL(string: value), url.scheme != nil, url.host != nil else { return nil }
        return url
    }

    /// Splits a raw cURL capture into the raw `-H "Name: Value"` / `--header 'Name: Value'` header
    /// field strings it contains, unescaping shell quoting (including ANSI-C `$'...'` strings).
    public static func headerFields(from raw: String) -> [String] {
        var fields: [String] = []
        let pattern =
            #"(?s)(?:^|\s)(?:-H|--header)(?:\s+|=|(?=['"$]))"# +
            #"(?:\$'((?:\\.|[^'])*)'|'([^']*)'|"((?:\\.|[^"])*)"|(\S+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return fields }
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        for match in regex.matches(in: raw, options: [], range: range) {
            if let ansi = self.capture(1, in: match, raw: raw) {
                fields.append(self.unescapeShellSegment(ansi, ansi: true))
            } else if let single = self.capture(2, in: match, raw: raw) {
                fields.append(single)
            } else if let double = self.capture(3, in: match, raw: raw) {
                fields.append(self.unescapeShellSegment(double, ansi: false))
            } else if let bare = self.capture(4, in: match, raw: raw) {
                fields.append(self.unescapeShellSegment(bare, ansi: false))
            }
        }
        return fields
    }

    /// Returns the value of the first header field whose name matches `name` (case-insensitive).
    public static func headerValue(named name: String, in fields: [String]) -> String? {
        for field in fields {
            guard let colon = field.firstIndex(of: ":") else { continue }
            let rawName = field[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
            guard rawName.caseInsensitiveCompare(name) == .orderedSame else { continue }
            let value = field[field.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return nil
    }

    /// Builds a `[canonicalHeaderName: value]` map from `fields`, keeping only headers whose
    /// lowercased name appears in `allowlist` (mapping lowercase name -> canonical HTTP header name).
    public static func forwardedHeaders(from fields: [String], allowlist: [String: String]) -> [String: String] {
        var headers: [String: String] = [:]
        for field in fields {
            guard let colon = field.firstIndex(of: ":") else { continue }
            let rawName = field[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = field[field.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawName.isEmpty, !value.isEmpty else { continue }
            guard let canonical = allowlist[rawName.lowercased()] else { continue }
            headers[canonical] = value
        }
        return headers
    }

    private static func capture(_ index: Int, in match: NSTextCheckingResult, raw: String) -> String? {
        guard match.numberOfRanges > index,
              let range = Range(match.range(at: index), in: raw)
        else {
            return nil
        }
        return String(raw[range])
    }

    private static func unescapeShellSegment(_ raw: String, ansi: Bool) -> String {
        var output = ""
        var index = raw.startIndex
        while index < raw.endIndex {
            guard raw[index] == "\\" else {
                output.append(raw[index])
                index = raw.index(after: index)
                continue
            }
            let next = raw.index(after: index)
            guard next < raw.endIndex else { return output }
            switch raw[next] {
            case "n" where ansi:
                output.append("\n")
            case "r" where ansi:
                output.append("\r")
            case "t" where ansi:
                output.append("\t")
            case "\n":
                break
            default:
                output.append(raw[next])
            }
            index = raw.index(after: next)
        }
        return output
    }
}
