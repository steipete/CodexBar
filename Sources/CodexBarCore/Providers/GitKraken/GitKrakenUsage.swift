import Foundation

/// GitKraken's credit API and the CLI's reported allowance are deliberately not converted into one another.
struct GitKrakenUsage: Equatable, Sendable {
    enum Unit: String, Sendable {
        case credits
        case tokens
        case allowance
    }

    struct Quota: Decodable, Equatable, Sendable {
        let used: Double
        let limit: Double

        init(used: Double, limit: Double) throws {
            guard used.isFinite, used >= 0, limit.isFinite, limit >= 0 || limit == -1,
                  limit <= 0 || (used / limit * 100).isFinite
            else { throw GitKrakenUsageError.invalidResponse }
            self.used = used
            self.limit = limit
        }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(
                used: values.decode(Double.self, forKey: .used),
                limit: values.decode(Double.self, forKey: .limit))
        }

        private enum CodingKeys: String, CodingKey {
            case used, limit
        }

        var usedPercent: Double? {
            self.limit > 0 ? self.used / self.limit * 100 : nil
        }

        func description(unit: Unit) -> String {
            let used = Self.format(self.used)
            let suffix = unit == .allowance ? "" : " \(unit.rawValue)"
            switch self.limit {
            case -1: return "\(used)\(suffix) used · Unlimited"
            case 0: return "\(used)\(suffix) used · No allowance"
            default: return "\(used) / \(Self.format(self.limit))\(suffix) used"
            }
        }

        static func format(_ value: Double) -> String {
            value.formatted(.number.precision(.fractionLength(0...2)))
        }
    }

    let personal: Quota
    let organization: Quota?
    let sharedUsed: Double?
    let resetsAt: Date?
    let resetDescription: String?
    let unit: Unit

    /// Contract: GitLens src/plus/ai/aiProviderService.ts, GET v1/ai-tasks/usage.
    /// The personal record is required; malformed supplementary organization data is not a zero balance.
    static func parseAPI(_ data: Data) throws -> Self {
        guard data.count <= 65536 else { throw GitKrakenUsageError.responseTooLarge }
        do {
            let payload = try JSONDecoder().decode(APIEnvelope.self, from: data).data
            guard let resetsAt = Self.parseTimestamp(payload.resetsOn) else {
                throw GitKrakenUsageError.invalidResponse
            }
            return Self(
                personal: payload.personal,
                organization: payload.organization,
                sharedUsed: payload.sharedUsed,
                resetsAt: resetsAt,
                resetDescription: nil,
                unit: .credits)
        } catch let error as GitKrakenUsageError {
            throw error
        } catch {
            // Do not put response bodies or decoder debug descriptions into diagnostics.
            throw GitKrakenUsageError.invalidResponse
        }
    }

    /// Parses the documented `gk ai tokens` display, not an assumed CLI JSON schema.
    /// A date-only reset must not become a made-up midnight timestamp or countdown.
    static func parseCLI(_ output: String) throws -> Self {
        guard output.utf8.count <= 65536 else { throw GitKrakenUsageError.responseTooLarge }
        let text = output
            .replacingOccurrences(of: "\u{001B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r\n", with: "\n")
        let number = #"(?:[0-9]+|[0-9]{1,3}(?:,[0-9]{3})+)(?:\.[0-9]+)?"#
        let pattern = #"(?im)^\h*("# + number + #")\h+of\h+("# + number +
            #"|-1|unlimited)\h+(?:(tokens|credits)\h+)?used\h*(?:\([0-9]+(?:\.[0-9]+)?%\h+consumed\))?\h*$"#
        let usage = try Self.singleMatch(pattern, in: text)
        let reset = try Self.singleMatch(#"(?im)^\h*Resets? on\h+([0-9]{2}/[0-9]{2}/[0-9]{4})\h*$"#, in: text)
        guard let used = Double(usage[0].replacingOccurrences(of: ",", with: "")),
              let limit = usage[1].lowercased() == "unlimited"
              ? -1 : Double(usage[1].replacingOccurrences(of: ",", with: "")),
              Self.isCalendarDate(reset[0])
        else { throw GitKrakenUsageError.invalidCLIOutput }
        let personal: Quota
        do {
            personal = try Quota(used: used, limit: limit)
        } catch {
            throw GitKrakenUsageError.invalidCLIOutput
        }
        return Self(
            personal: personal,
            organization: nil,
            sharedUsed: nil,
            resetsAt: nil,
            resetDescription: "Resets on \(reset[0])",
            unit: Unit(rawValue: usage[2].lowercased()) ?? .allowance)
    }

    private static func singleMatch(_ pattern: String, in text: String) throws -> [String] {
        let expression = try NSRegularExpression(pattern: pattern)
        let matches = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard matches.count == 1, let match = matches.first else {
            throw GitKrakenUsageError.invalidCLIOutput
        }
        return (1..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }

    private static func isCalendarDate(_ text: String) -> Bool {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "MM/dd/yyyy"
        formatter.isLenient = false
        guard let date = formatter.date(from: text) else { return false }
        return formatter.string(from: date) == text
    }

    private static func parseTimestamp(_ text: String) -> Date? {
        // Require the timezone; never interpret an API timestamp in this machine's local timezone.
        guard text.range(
            of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$"#,
            options: .regularExpression) != nil
        else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    private struct APIEnvelope: Decodable {
        let data: Payload

        private enum CodingKeys: String, CodingKey {
            case data, error
        }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            if values.contains(.error), try !values.decodeNil(forKey: .error) {
                throw GitKrakenUsageError.invalidResponse
            }
            self.data = try values.decode(Payload.self, forKey: .data)
        }
    }

    private struct Payload: Decodable {
        let personal: Quota
        let organization: Quota?
        let sharedUsed: Double?
        let resetsOn: String

        private enum CodingKeys: String, CodingKey {
            case organization, sharedUsed, resetsOn
        }

        init(from decoder: any Decoder) throws {
            self.personal = try Quota(from: decoder)
            let values = try decoder.container(keyedBy: CodingKeys.self)
            self.resetsOn = try values.decode(String.self, forKey: .resetsOn)
            self.organization = try? values.decode(Quota.self, forKey: .organization)
            let shared = try? values.decode(Double.self, forKey: .sharedUsed)
            if let shared, shared.isFinite, shared >= 0,
               let organization = self.organization, shared <= organization.used
            {
                self.sharedUsed = shared
            } else {
                self.sharedUsed = nil
            }
        }
    }
}

extension GitKrakenUsage {
    func toUsageSnapshot(source: String, now: Date = Date()) -> UsageSnapshot {
        var rows: [ProviderDetailSection.Row] = [
            .makeRow(label: "Personal", value: self.personal.description(unit: self.unit)),
        ]
        if let organization = self.organization {
            rows.append(.makeRow(label: "Shared pool", value: organization.description(unit: self.unit)))
            if let sharedUsed = self.sharedUsed {
                rows.append(.makeRow(label: "Your shared usage", value: "\(Quota.format(sharedUsed)) credits"))
                rows.append(.makeRow(
                    label: "Rest of organization", value: "\(Quota.format(organization.used - sharedUsed)) credits"))
            }
        }
        if let resetDescription = self.resetDescription {
            rows.append(.makeRow(label: "Reset", value: resetDescription))
        } else if let resetsAt = self.resetsAt {
            rows.append(.makeRow(label: "Reset", value: resetsAt.formatted(date: .abbreviated, time: .shortened)))
        }
        return UsageSnapshot(
            primary: self.window(self.personal),
            secondary: self.organization.flatMap(self.window),
            details: [.makeSection(title: "Weekly usage", rows: rows)],
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .gitkraken,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: source))
    }

    private func window(_ quota: Quota) -> RateWindow? {
        guard let percent = quota.usedPercent else { return nil }
        return RateWindow(
            usedPercent: percent,
            windowMinutes: 10080,
            resetsAt: self.resetsAt,
            resetDescription: self.resetDescription)
    }
}

/// Error messages never include tokens, raw subprocess output, or HTTP response bodies.
enum GitKrakenUsageError: LocalizedError, Equatable, Sendable {
    case missingToken
    case invalidToken
    case invalidOrganization
    case invalidResponse
    case invalidCLIOutput
    case responseTooLarge
    case cliFailed
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .missingToken:
            "Set a GitKraken access token in provider settings or GITKRAKEN_API_TOKEN, or use CLI mode."
        case .invalidToken:
            "Invalid GitKraken access token. Paste the token value only, without the Bearer prefix or whitespace."
        case .invalidOrganization:
            "Invalid GitKraken organization ID. Enter a single ID without whitespace."
        case .invalidResponse:
            "GitKraken returned an unrecognized usage response. No usage measurement was published."
        case .invalidCLIOutput:
            "Unrecognized gk ai tokens output. Update GitKraken CLI or use API mode."
        case .responseTooLarge:
            "GitKraken usage response exceeded the size limit."
        case .cliFailed:
            "GitKraken CLI failed. Run gk auth login, then check gk ai tokens in your terminal."
        case .httpError(401), .httpError(403):
            "GitKraken rejected the access token or organization. Update API credentials or use CLI mode."
        case .httpError(429):
            "GitKraken rate limited usage requests. Wait before refreshing again."
        case let .httpError(status):
            "GitKraken usage request failed (HTTP \(status))."
        }
    }
}
