import Foundation

enum AuditPrivacySanitizer {
    private static let homeDirectoryPath = FileManager.default.homeDirectoryForCurrentUser.path
    private static let resourceIdentifierPattern =
        #"(?i)^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$|^[0-9a-f]{24,}$"#
    private static let resourceIdentifierRegex = try? NSRegularExpression(pattern: Self.resourceIdentifierPattern)
    private static let embeddedURLRegex = try? NSRegularExpression(pattern: #"https?://[^\s)]+"#)
    private static let embeddedHomePathRegex = try? NSRegularExpression(
        pattern: #"~\/[^\n)]*?(?=(?: \(|[),;]|$))"#)

    static func sanitizeEvent(_ event: AuditEvent) -> AuditEvent {
        AuditEvent(
            timestamp: event.timestamp,
            category: event.category,
            action: self.sanitizeText(event.action),
            target: self.sanitizeText(event.target),
            risk: event.risk,
            metadata: self.sanitizeMetadata(event.metadata),
            context: event.context.map {
                GovernanceContext(
                    flow: self.sanitizeText($0.flow),
                    detail: $0.detail.map(self.sanitizeText))
            })
    }

    static func sanitizeMetadata(_ metadata: [String: String]) -> [String: String] {
        metadata.reduce(into: [:]) { partial, entry in
            partial[entry.key] = self.sanitizeText(entry.value)
        }
    }

    static func sanitizeText(_ value: String) -> String {
        let redacted = LogRedactor.redact(value)
        let homeNormalized = self.normalizeHomePath(in: redacted)
        let embeddedURLsSanitized = self.redactEmbeddedURLs(in: homeNormalized)
        let embeddedPathsSanitized = self.redactEmbeddedHomePaths(in: embeddedURLsSanitized)
        if let urlSanitized = self.redactResourceIdentifiersInURL(embeddedPathsSanitized) {
            return urlSanitized
        }
        return self.redactResourceIdentifiersInPath(embeddedPathsSanitized)
    }

    static func redactPathSegments(in path: String) -> String {
        let hasLeadingSlash = path.hasPrefix("/")
        let hasHomePrefix = path.hasPrefix("~/")
        let leading = hasHomePrefix ? "~/" : (hasLeadingSlash ? "/" : "")
        let trimmed: String = if hasHomePrefix {
            String(path.dropFirst(2))
        } else if hasLeadingSlash {
            String(path.dropFirst())
        } else {
            path
        }

        let sanitizedSegments = trimmed
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { segment -> String in
                let text = String(segment)
                return self.looksLikeResourceIdentifier(text) ? "<id>" : text
            }
        return leading + sanitizedSegments.joined(separator: "/")
    }

    private static func normalizeHomePath(in value: String) -> String {
        guard value.contains(self.homeDirectoryPath) else { return value }
        return value.replacingOccurrences(of: self.homeDirectoryPath, with: "~")
    }

    private static func redactEmbeddedURLs(in value: String) -> String {
        self.replacingMatches(in: value, regex: self.embeddedURLRegex) { match in
            self.redactResourceIdentifiersInURL(match) ?? match
        }
    }

    private static func redactEmbeddedHomePaths(in value: String) -> String {
        self.replacingMatches(in: value, regex: self.embeddedHomePathRegex) { match in
            self.redactPathSegments(in: match)
        }
    }

    private static func redactResourceIdentifiersInURL(_ value: String) -> String? {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme,
              let host = components.host
        else {
            return nil
        }

        var sanitized = "\(scheme)://\(host)"
        if let port = components.port {
            sanitized += ":\(port)"
        }
        sanitized += self.redactPathSegments(in: components.path.isEmpty ? "/" : components.path)
        return sanitized
    }

    private static func redactResourceIdentifiersInPath(_ value: String) -> String {
        if value.hasPrefix("~/") || value.hasPrefix("/") {
            return self.redactPathSegments(in: value)
        }
        return value
    }

    private static func looksLikeResourceIdentifier(_ segment: String) -> Bool {
        let range = NSRange(segment.startIndex..<segment.endIndex, in: segment)
        return self.resourceIdentifierRegex?.firstMatch(in: segment, options: [], range: range) != nil
    }

    private static func replacingMatches(
        in value: String,
        regex: NSRegularExpression?,
        transform: (String) -> String)
        -> String
    {
        guard let regex else { return value }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        let matches = regex.matches(in: value, options: [], range: range)
        guard !matches.isEmpty else { return value }

        var result = value
        for match in matches.reversed() {
            guard let matchRange = Range(match.range, in: result) else { continue }
            let original = String(result[matchRange])
            let replacement = transform(original)
            result.replaceSubrange(matchRange, with: replacement)
        }
        return result
    }
}
