import CoreFoundation
import Foundation

enum AlibabaTokenPlanCLIUsageError: LocalizedError, Sendable, Equatable {
    case unavailable
    case commandFailed
    case timedOut
    case invalidOutput

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Bailian CLI 'bl' is not installed or not on PATH."
        case .commandFailed:
            "Bailian CLI could not load Token Plan usage. Sign in with 'bl' and try again."
        case .timedOut:
            "Bailian CLI Token Plan usage timed out."
        case .invalidOutput:
            "Bailian CLI returned an unsupported Token Plan usage response."
        }
    }
}

enum AlibabaTokenPlanCLIUsageParser {
    struct TeamPage: Decodable {
        let success: Bool
        let data: SeatPage

        enum CodingKeys: String, CodingKey {
            case success = "Success", data = "Data"
        }

        struct SeatPage: Decodable {
            let items: [Seat]
            let total: Int
            let pageNo: Int
            let pageSize: Int

            enum CodingKeys: String, CodingKey {
                case items = "Items", total = "Total", pageNo = "PageNo", pageSize = "PageSize"
            }
        }

        struct Seat: Decodable {
            let seatID: String
            let status: String
            let startTime: Double?
            let endTime: Double?
            let equityList: [Equity]?

            enum CodingKeys: String, CodingKey {
                case seatID = "SeatId", status = "Status", startTime = "StartTime", endTime = "EndTime"
                case equityList = "EquityList"
            }
        }

        struct Equity: Decodable {
            let type: String
            let startTime: Double?
            let endTime: Double?
            let total: Double?
            let remaining: Double?

            enum CodingKeys: String, CodingKey {
                case type = "EquityType", startTime = "CycleStartTime", endTime = "CycleEndTime"
                case total = "CycleTotalValue", remaining = "CycleSurplusValue"
            }
        }
    }

    static func teamPage(_ data: Data, pageNo: Int) throws -> TeamPage {
        guard let page = try? JSONDecoder().decode(TeamPage.self, from: data),
              page.success, page.data.pageNo == pageNo,
              page.data.pageSize == AlibabaTokenPlanCLIUsageFetcher.teamPageSize,
              (0...AlibabaTokenPlanCLIUsageFetcher.maxTeamSeats).contains(page.data.total),
              page.data.items.count <= page.data.pageSize
        else { throw AlibabaTokenPlanCLIUsageError.invalidOutput }
        return page
    }

    static func teamUsage(_ pages: [TeamPage], now: Date) throws -> AlibabaTokenPlanUsageSnapshot {
        guard let totalSeats = pages.first?.data.total,
              pages.allSatisfy({ $0.data.total == totalSeats }),
              pages.reduce(0, { $0 + $1.data.items.count }) == totalSeats
        else { throw AlibabaTokenPlanCLIUsageError.invalidOutput }

        var seenSeats = Set<String>()
        var total = 0.0
        var remaining = 0.0
        var cycleEnds = Set<Double>()
        let milliseconds = now.timeIntervalSince1970 * 1000
        for seat in pages.flatMap(\.data.items) {
            guard !seat.seatID.isEmpty, seenSeats.insert(seat.seatID).inserted else {
                throw AlibabaTokenPlanCLIUsageError.invalidOutput
            }
            guard seat.status == "NORMAL" else { continue }
            guard let start = seat.startTime, let end = seat.endTime,
                  start.isFinite, end.isFinite, start > 0, end > start
            else { throw AlibabaTokenPlanCLIUsageError.invalidOutput }
            guard start <= milliseconds, milliseconds < end else { continue }
            let credits = (seat.equityList ?? []).filter { $0.type == "CREDITS" }
            // The API promises one current equity per seat. Do not add resource packs or historical cycles.
            guard credits.count == 1, let equity = credits.first,
                  let cycleStart = equity.startTime, let cycleEnd = equity.endTime,
                  cycleStart.isFinite, cycleEnd.isFinite, cycleStart > 0,
                  cycleStart <= milliseconds, milliseconds < cycleEnd,
                  let seatTotal = equity.total, let seatRemaining = equity.remaining,
                  seatTotal.isFinite, seatRemaining.isFinite, seatTotal >= 0,
                  seatRemaining >= 0, seatRemaining <= seatTotal
            else { throw AlibabaTokenPlanCLIUsageError.invalidOutput }
            total += seatTotal
            remaining += seatRemaining
            cycleEnds.insert(cycleEnd)
        }
        guard total > 0, total.isFinite, remaining.isFinite else {
            throw AlibabaTokenPlanCLIUsageError.invalidOutput
        }
        // An aggregate of seats with different cycles has no single reset time.
        let resetsAt = cycleEnds.count == 1 ? cycleEnds.first.map { Date(timeIntervalSince1970: $0 / 1000) } : nil
        return AlibabaTokenPlanUsageSnapshot(
            planName: "Token Plan",
            usedQuota: total - remaining,
            totalQuota: total,
            remainingQuota: remaining,
            resetsAt: resetsAt,
            updatedAt: now)
    }

    static func parse(_ data: Data, now: Date = Date()) throws -> AlibabaTokenPlanUsageSnapshot {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              object is [String: Any],
              let snapshot = AlibabaTokenPlanUsageSnapshot.personalUsage(
                  in: OneConsoleJSON.expandEmbeddedJSON(object),
                  subscriptionData: nil,
                  quotaConfigData: nil,
                  defaultPlanName: "Token Plan",
                  now: now,
                  ratio: self.ratio,
                  resetDate: self.resetDate,
                  requiresUsageForReset: true)
        else {
            throw AlibabaTokenPlanCLIUsageError.invalidOutput
        }

        return snapshot
    }

    private static func ratio(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let ratio = number.doubleValue
        return ratio.isFinite && (0...1).contains(ratio) ? ratio : nil
    }

    private static func resetDate(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let milliseconds = number.doubleValue
        guard milliseconds.isFinite, milliseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }
}

enum AlibabaTokenPlanCLIUsageFetcher {
    static let timeout: TimeInterval = 15
    static let maxOutputBytes = 64 * 1024
    static let teamPageSize = 10
    static let maxTeamSeats = 1000

    /// Environment keys the Bailian CLI child process may legitimately observe.
    /// The ambient session is narrowed to this allowlist before spawning `bl`:
    /// PATH resolution, per-user auth/config discovery (HOME), locale encoding,
    /// timezone, and network proxy configuration. Every other variable —
    /// cookies, API keys, cloud/CI secrets — must never cross the process boundary.
    static let childEnvironmentAllowlist: Set<String> = [
        "PATH", "HOME",
        "LANG", "LC_ALL", "LC_CTYPE", "TZ",
        "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
        "http_proxy", "https_proxy", "all_proxy", "no_proxy",
    ]

    /// Builds the smallest practical child environment for the Bailian CLI:
    /// only the allowlisted keys survive, so unrelated ambient secrets never
    /// reach the subprocess.
    static func sanitizedEnvironment(_ environment: [String: String]) -> [String: String] {
        environment.filter { self.childEnvironmentAllowlist.contains($0.key) }
    }

    static func arguments(region: AlibabaTokenPlanAPIRegion, pageNo: Int = 1) -> [String] {
        guard region.usesPersonalTokenPlanAPI else {
            return [
                "token-plan", "list-seats", "--page-no", String(pageNo),
                "--page-size", String(self.teamPageSize), "--output", "json",
            ]
        }
        return [
            "console", "call", "--api", "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage", "--data", "{}",
            "--console-region", region.currentRegionID,
            "--console-site", region.cliConsoleSite,
            "--output", "json",
        ]
    }

    static func teamBaseURL(region: AlibabaTokenPlanAPIRegion) -> String {
        region == .international ? "https://dashscope-intl.aliyuncs.com" : "https://dashscope.aliyuncs.com"
    }

    static func fetch(
        region: AlibabaTokenPlanAPIRegion,
        environment: [String: String],
        now: Date = Date()) async throws -> AlibabaTokenPlanUsageSnapshot
    {
        var processEnvironment = Self.sanitizedEnvironment(environment)
        processEnvironment["PATH"] = PathBuilder.effectivePATH(
            purposes: [.tty],
            env: environment,
            loginPATH: LoginShellPathCache.shared.current)
        guard let binary = self.resolveBinary(environment: processEnvironment) else {
            throw AlibabaTokenPlanCLIUsageError.unavailable
        }
        do {
            if !region.usesPersonalTokenPlanAPI {
                // list-seats selects its OpenAPI region from the model base URL, not console-region/site.
                // This value is provider-owned; never forward an ambient endpoint or credential.
                processEnvironment["BAILIAN_BASE_URL"] = self.teamBaseURL(region: region)
                processEnvironment["DASHSCOPE_BASE_URL"] = self.teamBaseURL(region: region)
                return try await self.fetchTeam(
                    binary: binary, region: region, environment: processEnvironment, now: now)
            }
            let result = try await SubprocessRunner.run(
                binary: binary,
                arguments: self.arguments(region: region),
                environment: processEnvironment,
                timeout: self.timeout,
                maxOutputBytes: self.maxOutputBytes,
                label: "bailian-token-plan-usage")
            return try AlibabaTokenPlanCLIUsageParser.parse(Data(result.stdout.utf8), now: now)
        } catch let error as AlibabaTokenPlanCLIUsageError {
            throw error
        } catch let error as SubprocessRunnerError {
            switch error {
            case .timedOut:
                throw AlibabaTokenPlanCLIUsageError.timedOut
            case .binaryNotFound:
                throw AlibabaTokenPlanCLIUsageError.unavailable
            case .launchFailed, .outputTooLarge, .nonZeroExit:
                throw AlibabaTokenPlanCLIUsageError.commandFailed
            }
        } catch let error as CancellationError {
            throw error
        } catch {
            throw AlibabaTokenPlanCLIUsageError.commandFailed
        }
    }

    private static func fetchTeam(
        binary: String,
        region: AlibabaTokenPlanAPIRegion,
        environment: [String: String],
        now: Date) async throws -> AlibabaTokenPlanUsageSnapshot
    {
        let deadline = Date().addingTimeInterval(self.timeout)
        var pages: [AlibabaTokenPlanCLIUsageParser.TeamPage] = []
        var received = 0
        repeat {
            try Task.checkCancellation()
            let remainingTime = deadline.timeIntervalSinceNow
            guard remainingTime > 0 else { throw AlibabaTokenPlanCLIUsageError.timedOut }
            let pageNo = pages.count + 1
            let result = try await SubprocessRunner.run(
                binary: binary,
                arguments: self.arguments(region: region, pageNo: pageNo),
                environment: environment,
                timeout: remainingTime,
                maxOutputBytes: self.maxOutputBytes,
                label: "bailian-token-plan-seats")
            let page = try AlibabaTokenPlanCLIUsageParser.teamPage(Data(result.stdout.utf8), pageNo: pageNo)
            received += page.data.items.count
            guard received <= page.data.total,
                  pages.first.map({ $0.data.total == page.data.total }) ?? true,
                  received == page.data.total || page.data.items.count == self.teamPageSize
            else { throw AlibabaTokenPlanCLIUsageError.invalidOutput }
            pages.append(page)
            if received == page.data.total { break }
        } while pages.count < self.maxTeamSeats / self.teamPageSize
        return try AlibabaTokenPlanCLIUsageParser.teamUsage(pages, now: now)
    }

    static func resolveBinary(
        environment: [String: String],
        fileManager: FileManager = .default) -> String?
    {
        guard let path = environment["PATH"] else { return nil }
        return BinaryLocator.find("bl", in: path.split(separator: ":").map(String.init), fileManager: fileManager)
    }
}
