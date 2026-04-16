import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct GovernanceSummaryEntry: Codable, Equatable {
    let key: String
    let day: String
    let category: AuditCategory
    let action: String
    let target: String
    let resource: String
    let risk: AuditRisk
    let flow: String?
    let detail: String?
    var count: Int
    var firstSeen: Date
    var lastSeen: Date
}

private enum GovernanceSummaryStatus: String {
    case expected = "Expected"
    case unexpected = "Unexpected"
}

private struct GovernanceSummaryInterpretation: Equatable {
    let status: GovernanceSummaryStatus
    let why: String
}

struct GovernanceSummaryState: Codable, Equatable {
    var entries: [GovernanceSummaryEntry] = []

    mutating func record(_ event: AuditEvent) {
        let day = Self.dayString(for: event.timestamp)
        let resource = Self.resource(for: event)
        let key = [
            day,
            event.category.rawValue,
            event.action,
            event.target,
            resource,
            event.risk.rawValue,
            event.context?.flow ?? "",
            event.context?.detail ?? "",
        ].joined(separator: "||")

        if let index = self.entries.firstIndex(where: { $0.key == key }) {
            self.entries[index].count += 1
            self.entries[index].lastSeen = event.timestamp
            return
        }

        self.entries.append(GovernanceSummaryEntry(
            key: key,
            day: day,
            category: event.category,
            action: event.action,
            target: event.target,
            resource: resource,
            risk: event.risk,
            flow: event.context?.flow,
            detail: event.context?.detail,
            count: 1,
            firstSeen: event.timestamp,
            lastSeen: event.timestamp))
    }

    private static func dayString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func resource(for event: AuditEvent) -> String {
        let priorityKeys = ["path", "service", "account", "binary", "host"]
        for key in priorityKeys {
            if let value = event.metadata[key], !value.isEmpty {
                return value
            }
        }
        return event.target
    }
}

enum GovernanceSummaryRenderer {
    static func render(_ state: GovernanceSummaryState) -> String {
        var lines = [
            "# Governance Audit Summary",
            "",
            "Human-readable summary of privacy-sensitive and elevated-risk actions captured by Governance Audit Mode.",
            "",
        ]

        guard !state.entries.isEmpty else {
            lines.append("No governance audit events have been recorded yet.")
            lines.append("")
            return lines.joined(separator: "\n")
        }

        let groupedByDay = Dictionary(grouping: state.entries) { $0.day }
        for day in groupedByDay.keys.sorted(by: >) {
            lines.append("## \(day)")
            lines.append("")

            let entries = groupedByDay[day, default: []]
            for risk in [AuditRisk.elevatedRisk, .sensitive, .normal] {
                let riskEntries = entries
                    .filter { $0.risk == risk }
                    .sorted { lhs, rhs in
                        if lhs.lastSeen == rhs.lastSeen {
                            return lhs.action < rhs.action
                        }
                        return lhs.lastSeen > rhs.lastSeen
                    }
                guard !riskEntries.isEmpty else { continue }

                lines.append("### \(self.heading(for: risk))")
                lines.append("")
                for entry in riskEntries {
                    let interpretation = self.interpret(entry)
                    lines.append("- **\(self.title(for: entry.action))**")
                    lines.append("  - Count: \(entry.count)")
                    lines.append("  - Resource: `\(entry.resource)`")
                    lines.append("  - First seen: \(self.timeString(entry.firstSeen))")
                    lines.append("  - Last seen: \(self.timeString(entry.lastSeen))")
                    lines.append("  - Risk: \(self.riskLabel(entry.risk))")
                    lines.append("  - Status: \(interpretation.status.rawValue)")
                    lines.append("  - Why: \(interpretation.why)")
                }
                lines.append("")
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func heading(for risk: AuditRisk) -> String {
        switch risk {
        case .elevatedRisk: "Elevated-risk events"
        case .sensitive: "Sensitive events"
        case .normal: "Observed events"
        }
    }

    private static func riskLabel(_ risk: AuditRisk) -> String {
        switch risk {
        case .elevatedRisk: "Elevated risk"
        case .sensitive: "Sensitive"
        case .normal: "Observed"
        }
    }

    private static func interpret(_ entry: GovernanceSummaryEntry) -> GovernanceSummaryInterpretation {
        if entry.category == .secret, entry.action == "file.auth_json.read", entry.resource == "~/.codex/auth.json" {
            return GovernanceSummaryInterpretation(
                status: .expected,
                why: "Needed for normal Codex authentication and usage probing.")
        }

        if entry.category == .secret,
           entry.action == "keychain.preflight",
           self.expectedKeychainServices.contains(entry.resource)
        {
            return GovernanceSummaryInterpretation(
                status: .expected,
                why: "Expected keychain preflight for browser or provider credentials before reading secrets.")
        }

        if entry.category == .secret,
           self.expectedSecretActions.contains(entry.action)
        {
            return GovernanceSummaryInterpretation(
                status: .expected,
                why: self.secretWhy(for: entry.action))
        }

        if entry.category == .command,
           self.expectedCommandActions.contains(entry.action)
        {
            return GovernanceSummaryInterpretation(
                status: .expected,
                why: self.commandWhy(for: entry.action, target: entry.resource))
        }

        if entry.category == .network {
            if self.expectedLocalNetworkActions.contains(entry.action),
               entry.flow == "antigravity-localhost-trust"
            {
                return GovernanceSummaryInterpretation(
                    status: .expected,
                    why: "Expected localhost trust override or fallback used for Antigravity local connectivity checks.")
            }

            if let host = self.host(from: entry.target) {
                if self.expectedNetworkHosts.contains(host) {
                    return GovernanceSummaryInterpretation(
                        status: .expected,
                        why: self.networkWhy(for: entry.action, host: host))
                }

                return GovernanceSummaryInterpretation(
                    status: .unexpected,
                    why: "Outside the known set of CodexBar provider and authentication hosts.")
            }
        }

        return GovernanceSummaryInterpretation(
            status: .expected,
            why: "Observed within CodexBar's known governance-audited command, network, or credential flows.")
    }

    private static func host(from target: String) -> String? {
        guard let url = URL(string: target), let host = url.host?.lowercased(), !host.isEmpty else {
            return nil
        }
        return host
    }

    private static let expectedSecretActions: Set<String> = [
        "file.auth_json.read",
        "file.auth_json.write",
        "keychain.cookie_header.read",
        "keychain.cookie_header.write",
        "keychain.cookie_header.delete",
        "keychain.cache.read",
        "keychain.cache.write",
        "keychain.cache.delete",
        "keychain.prompt_requested",
        "keychain.browser_cookie_prompt_requested",
        "keychain.read_via_security_cli",
        "oauth.credentials.read",
        "oauth.credentials.write",
        "oauth.credentials.refresh",
    ]

    private static let expectedKeychainServices: Set<String> = [
        "Chrome Safe Storage",
        "Claude Code-credentials",
        "com.steipete.CodexBar",
    ]

    private static let expectedCommandTargets: Set<String> = [
        "security",
        "ps",
        "codex",
        "claude",
        "gemini",
        "kilo",
        "kiro",
        "auggie",
    ]

    private static let expectedCommandActions: Set<String> = [
        "process.started",
        "process.launched",
        "process.launch_failed",
        "process.timed_out",
        "process.failed",
        "process.error",
        "process.completed",
    ]

    private static let expectedLocalNetworkActions: Set<String> = [
        "request.http_fallback",
        "trust_override.accepted",
    ]

    private static let expectedNetworkHosts: Set<String> = [
        "127.0.0.1",
        "localhost",
        "ampcode.com",
        "api.anthropic.com",
        "api.factory.ai",
        "api.github.com",
        "api.minimax.io",
        "api.minimaxi.com",
        "chatgpt.com",
        "api.openai.com",
        "api.synthetic.new",
        "api.workos.com",
        "api.z.ai",
        "app.augmentcode.com",
        "app.factory.ai",
        "app.kilo.ai",
        "app.kiro.dev",
        "app.warp.dev",
        "auth.factory.ai",
        "auth.openai.com",
        "bailian-beijing-cs.aliyuncs.com",
        "bailian-singapore-cs.alibabacloud.com",
        "bailian.console.aliyun.com",
        "chat.openai.com",
        "claude.ai",
        "cloudcode-pa.googleapis.com",
        "cloudresourcemanager.googleapis.com",
        "code.claude.com",
        "console.anthropic.com",
        "console.cloud.google.com",
        "cursor.com",
        "docs.warp.dev",
        "gemini.google.com",
        "github.com",
        "health.aws.amazon.com",
        "kimi-k2.ai",
        "kiro.dev",
        "minimax.io",
        "minimaxi.com",
        "modelstudio.console.alibabacloud.com",
        "monitoring.googleapis.com",
        "openai.com",
        "oauth2.googleapis.com",
        "ollama.com",
        "open.bigmodel.cn",
        "opencode.ai",
        "openrouter.ai",
        "platform.claude.com",
        "platform.minimax.io",
        "platform.minimaxi.com",
        "status.aliyun.com",
        "status.claude.com",
        "status.cloud.google.com",
        "status.cursor.com",
        "status.factory.ai",
        "status.openai.com",
        "status.openrouter.ai",
        "status.perplexity.com",
        "www.githubstatus.com",
        "www.google.com",
        "www.googleapis.com",
        "www.kimi.com",
        "www.minimax.io",
        "www.minimaxi.com",
        "www.perplexity.ai",
        "z.ai",
    ]

    private static func secretWhy(for action: String) -> String {
        switch action {
        case "file.auth_json.read", "file.auth_json.write":
            return "Expected local auth-file access for provider authentication and account management."
        case "keychain.preflight":
            return "Expected keychain access check before reading provider or browser credentials."
        case "keychain.prompt_requested", "keychain.browser_cookie_prompt_requested":
            return "Expected prompt coordination when browser or keychain access requires user approval."
        case "keychain.cookie_header.read", "keychain.cookie_header.write", "keychain.cookie_header.delete":
            return "Expected cookie-header access during provider authentication and session management."
        case "keychain.cache.read", "keychain.cache.write", "keychain.cache.delete":
            return "Expected cached credential access used to persist provider state between refreshes."
        case "keychain.read_via_security_cli":
            return "Expected credential read path when Claude keychain access falls back to the security CLI."
        case "oauth.credentials.read", "oauth.credentials.write", "oauth.credentials.refresh":
            return "Expected OAuth credential access during normal token loading and refresh flows."
        default:
            return "Expected credential or cookie access during normal provider authentication flows."
        }
    }

    private static func commandWhy(for action: String, target: String) -> String {
        let loweredTarget = target.lowercased()
        if self.expectedCommandTargets.contains(loweredTarget) {
            return "Expected helper command used for provider detection, authentication, or usage probing."
        }

        switch action {
        case "process.started", "process.launched":
            return "Expected helper process launch during provider detection or usage probing."
        case "process.completed":
            return "Expected helper process completion during normal app flows."
        case "process.launch_failed", "process.timed_out", "process.failed", "process.error":
            return "Expected reporting for helper-process failures encountered during normal app flows."
        default:
            return "Expected command used during normal CodexBar helper-process flows."
        }
    }

    private static func networkWhy(for action: String, host: String) -> String {
        switch action {
        case "request.started", "request.completed", "request.failed":
            return "Expected network request to a known CodexBar provider, dashboard, or authentication endpoint."
        case "request.http_fallback", "trust_override.accepted":
            return "Expected elevated network behavior for Antigravity localhost connectivity and trust handling."
        default:
            return "Expected network access to a host supported by CodexBar."
        }
    }

    private static func title(for action: String) -> String {
        let separators = CharacterSet(charactersIn: "._-")
        let words = action
            .components(separatedBy: separators)
            .filter { !$0.isEmpty }
            .map { word -> String in
                switch word.lowercased() {
                case "json": "JSON"
                case "oauth": "OAuth"
                case "cli": "CLI"
                case "pty": "PTY"
                default: word.capitalized
                }
            }
        return words.joined(separator: " ")
    }

    private static func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

final class GovernanceSummarySink: @unchecked Sendable {
    static let shared = GovernanceSummarySink()
    static let defaultDirectoryURL: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        return base
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("CodexBar", isDirectory: true)
    }()

    static let summaryFileURL = GovernanceSummarySink.defaultDirectoryURL
        .appendingPathComponent("Governance Audit Summary.md", isDirectory: false)
    static let stateFileURL = GovernanceSummarySink.defaultDirectoryURL
        .appendingPathComponent(".governance-audit-state.json", isDirectory: false)
    static let legacyDirectoryURL = GovernanceSummarySink.defaultDirectoryURL
        .appendingPathComponent("Governance", isDirectory: true)
    static let lockFileURL = GovernanceSummarySink.defaultDirectoryURL
        .appendingPathComponent(".governance-audit.lock", isDirectory: false)

    private let queue = DispatchQueue(label: "com.steipete.codexbar.auditlog", qos: .utility)
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func write(_ event: AuditEvent) {
        self.queue.async {
            do {
                try self.prepareDirectory()
                try self.withLock {
                    var state = try self.loadState()
                    state.record(event)
                    try self.writeState(state)
                    try self.writeSummary(state)
                }
            } catch {
                // Keep audit logging non-fatal and silent.
            }
        }
    }

    func clear() throws {
        try self.queue.sync {
            try self.withLock {
                if self.fileManager.fileExists(atPath: Self.summaryFileURL.path) {
                    try self.fileManager.removeItem(at: Self.summaryFileURL)
                }
                if self.fileManager.fileExists(atPath: Self.stateFileURL.path) {
                    try self.fileManager.removeItem(at: Self.stateFileURL)
                }
                if self.fileManager.fileExists(atPath: Self.legacyDirectoryURL.path) {
                    try self.fileManager.removeItem(at: Self.legacyDirectoryURL)
                }
            }
        }
    }

    func ensureDirectoryExists() throws -> URL {
        try self.queue.sync {
            try self.prepareDirectory()
            return Self.defaultDirectoryURL
        }
    }

    private func prepareDirectory() throws {
        if !self.fileManager.fileExists(atPath: Self.defaultDirectoryURL.path) {
            try self.fileManager.createDirectory(
                at: Self.defaultDirectoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        if !self.fileManager.fileExists(atPath: Self.lockFileURL.path) {
            _ = self.fileManager.createFile(atPath: Self.lockFileURL.path, contents: nil)
        }
        try self.enforcePermissions(at: Self.lockFileURL, mode: 0o600)
    }

    private func enforcePermissions(at url: URL, mode: Int16) throws {
        let attributes = try? self.fileManager.attributesOfItem(atPath: url.path)
        let currentMode = (attributes?[.posixPermissions] as? NSNumber)?.int16Value
        if currentMode != mode {
            try self.fileManager.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: url.path)
        }
    }

    private func withLock<T>(_ operation: () throws -> T) throws -> T {
        let descriptor = open(Self.lockFileURL.path, O_RDWR | O_CREAT, 0o600)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try operation()
    }

    private func loadState() throws -> GovernanceSummaryState {
        guard self.fileManager.fileExists(atPath: Self.stateFileURL.path) else {
            return GovernanceSummaryState()
        }
        let data = try Data(contentsOf: Self.stateFileURL)
        guard !data.isEmpty else { return GovernanceSummaryState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(GovernanceSummaryState.self, from: data)
    }

    private func writeState(_ state: GovernanceSummaryState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)
        try data.write(to: Self.stateFileURL, options: .atomic)
        try self.enforcePermissions(at: Self.stateFileURL, mode: 0o600)
    }

    private func writeSummary(_ state: GovernanceSummaryState) throws {
        let markdown = GovernanceSummaryRenderer.render(state)
        try markdown.write(to: Self.summaryFileURL, atomically: true, encoding: .utf8)
        try self.enforcePermissions(at: Self.summaryFileURL, mode: 0o600)
    }
}

public enum AuditLogger {
    private static let sink = GovernanceSummarySink.shared
    private static let log = CodexBarLog.logger(LogCategories.governanceAudit)
    private static let sensitiveHeaderKeys = ["authorization", "cookie", "x-api-key"]

    public static var summaryFileURL: URL {
        GovernanceSummarySink.summaryFileURL
    }

    public static var logDirectoryURL: URL {
        GovernanceSummarySink.defaultDirectoryURL
    }

    public static func ensureLogDirectoryExists() throws -> URL {
        try self.sink.ensureDirectoryExists()
    }

    public static func clearLogs() throws {
        try self.sink.clear()
    }

    public static func record(_ event: AuditEvent) {
        guard AuditSettings.current().isEnabled(for: event.category) else { return }
        let sanitized = self.sanitizeForSummary(event)
        self.sink.write(sanitized)
    }

    public static func recordCommand(
        action: String,
        binary: String,
        risk: AuditRisk = .normal,
        metadata: [String: String] = [:],
        context: GovernanceContext? = nil)
    {
        self.record(AuditEvent(
            category: .command,
            action: action,
            target: URL(fileURLWithPath: binary).lastPathComponent,
            risk: risk,
            metadata: metadata,
            context: context))
    }

    public static func inferredCommandRisk(binary: String, usesShell: Bool = false) -> AuditRisk {
        if usesShell {
            return .elevatedRisk
        }

        let name = URL(fileURLWithPath: binary).lastPathComponent.lowercased()
        switch name {
        case "security":
            return .elevatedRisk
        case "codex", "claude", "gemini", "kilo", "kiro", "auggie":
            return .sensitive
        default:
            return .normal
        }
    }

    public static func recordSecretAccess(
        action: String,
        target: String,
        risk: AuditRisk = .sensitive,
        metadata: [String: String] = [:],
        context: GovernanceContext? = nil)
    {
        self.record(AuditEvent(
            category: .secret,
            action: action,
            target: target,
            risk: risk,
            metadata: metadata,
            context: context))
    }

    public static func recordNetwork(
        action: String,
        request: URLRequest,
        response: URLResponse? = nil,
        error: Error? = nil,
        risk: AuditRisk? = nil,
        metadata: [String: String] = [:],
        context: GovernanceContext? = nil)
    {
        let computedRisk = risk ?? self.defaultNetworkRisk(for: request)
        var combinedMetadata = metadata
        combinedMetadata["method"] = request.httpMethod ?? "GET"
        combinedMetadata["has_query"] = request.url?.query?.isEmpty == false ? "1" : "0"
        combinedMetadata["body_bytes"] = request.httpBody.map { "\($0.count)" } ?? "0"

        let headerKeys = request.allHTTPHeaderFields?.keys.map { $0.lowercased() } ?? []
        for header in self.sensitiveHeaderKeys {
            combinedMetadata["header_\(header.replacingOccurrences(of: "-", with: "_"))"] =
                headerKeys.contains(header) ? "1" : "0"
        }

        if let http = response as? HTTPURLResponse {
            combinedMetadata["status_code"] = "\(http.statusCode)"
        }
        if let error {
            let nsError = error as NSError
            combinedMetadata["error_domain"] = nsError.domain
            combinedMetadata["error_code"] = "\(nsError.code)"
        }

        self.record(AuditEvent(
            category: .network,
            action: action,
            target: self.networkTarget(for: request),
            risk: computedRisk,
            metadata: combinedMetadata,
            context: context))
    }

    static func sanitizeForPersistence(_ event: AuditEvent) -> AuditEvent {
        self.sanitizeForSummary(event)
    }

    static func sanitizeForSummary(_ event: AuditEvent) -> AuditEvent {
        AuditPrivacySanitizer.sanitizeEvent(event)
    }

    private static func networkTarget(for request: URLRequest) -> String {
        guard let url = request.url else { return "unknown" }
        var target = "\(url.scheme ?? "unknown")://\(url.host ?? "unknown")"
        if let port = url.port {
            target += ":\(port)"
        }
        target += url.path.isEmpty ? "/" : AuditPrivacySanitizer.redactPathSegments(in: url.path)
        return target
    }

    private static func defaultNetworkRisk(for request: URLRequest) -> AuditRisk {
        let headerKeys = Set((request.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() })
        if !headerKeys.isDisjoint(with: self.sensitiveHeaderKeys) {
            return .sensitive
        }
        return .normal
    }

    static func recordInternalFailure(_ message: String, metadata: [String: String] = [:]) {
        self.log.warning(message, metadata: AuditPrivacySanitizer.sanitizeMetadata(metadata))
    }
}
