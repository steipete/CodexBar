import Foundation
import Testing
@testable import CodexBarCore

struct CursorAccountBoundaryTests {
    private static let now = Date(timeIntervalSince1970: 1_793_000_000)
    private static let email = "shared-login@example.test"

    private static func status(
        isUnified: Bool?,
        membership: String = "enterprise") -> CursorStatusSnapshot
    {
        let formatter = ISO8601DateFormatter()
        return CursorStatusSnapshot(
            planPercentUsed: 20,
            planUsedUSD: 4,
            planLimitUSD: 20,
            onDemandUsedUSD: 0,
            onDemandLimitUSD: nil,
            teamOnDemandUsedUSD: nil,
            teamOnDemandLimitUSD: nil,
            billingCycleStart: Self.now.addingTimeInterval(-3 * 86400),
            billingCycleEnd: Self.now.addingTimeInterval(4 * 86400),
            membershipType: membership,
            accountEmail: Self.email,
            accountID: "cursor-fixture-account",
            accountName: nil,
            rawJSON: nil,
            sandUsage: CursorSandUsageStatus(
                currentPeriodStart: formatter.string(from: Self.now.addingTimeInterval(-86400)),
                nextResetTimestampUtc: formatter.string(from: Self.now.addingTimeInterval(6 * 86400)),
                usagePercent: 80,
                hasAvailableUsage: true,
                includedLimitZero: false,
                isUnified: isUnified))
    }

    @Test(arguments: [nil, false] as [Bool?], ["pro", "free_trial", "unified", "enterprise"])
    func `a seven day billing cycle does not unify independent allowances`(
        isUnified: Bool?, membership: String) throws
    {
        let snapshot = Self.status(isUnified: isUnified, membership: membership).toUsageSnapshot(now: Self.now)
        let primary = try #require(snapshot.primary)
        let bot = try #require(snapshot.extraRateWindows?.first { $0.id == CursorSandUsageStatus.extraWindowID })
        #expect(primary.windowMinutes == 10080)
        #expect(primary.usedPercent == 20)
        #expect(bot.window.usedPercent == 80)
        #expect(snapshot.identity?.accountEmail == Self.email)

        #expect(CursorProviderDescriptor.sharedWeeklyPool(snapshot: snapshot) == nil)
        #expect(CursorProviderDescriptor.primaryLabel(snapshot: snapshot) == nil)
        let menuBarBot = try #require(CursorProviderDescriptor.menuBarExtras(snapshot: snapshot).first {
            $0.id == CursorSandUsageStatus.extraWindowID
        })
        #expect(menuBarBot.window == bot.window)
        #expect(menuBarBot.window.usedPercent == 80)
    }

    @Test
    func `explicit unified evidence survives persistence and supplemental cost updates`() throws {
        let live = Self.status(isUnified: true).toUsageSnapshot(now: Self.now)
        let primary = try #require(live.primary)
        #expect(primary.usedPercent == 80)
        #expect(primary.windowMinutes == 10080)
        #expect(primary.resetsAt == Self.now.addingTimeInterval(6 * 86400))
        #expect(live.secondary == nil)
        #expect(live.tertiary == nil)
        #expect(live.extraRateWindows == nil)

        let restored = try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(live))
        let cost = ProviderCostSnapshot(
            used: 4, limit: 10, currencyCode: "USD", period: "Monthly", updatedAt: Self.now)
        let updated = restored.with(providerCost: cost)
        #expect(updated.providerCost?.used == 4)
        for snapshot in [live, restored, updated] {
            #expect(CursorProviderDescriptor.sharedWeeklyPool(snapshot: snapshot) == primary)
            #expect(CursorProviderDescriptor.primaryLabel(snapshot: snapshot) == "Weekly")
            let menuBarBot = try #require(CursorProviderDescriptor.menuBarExtras(snapshot: snapshot).first {
                $0.id == CursorSandUsageStatus.extraWindowID
            })
            #expect(menuBarBot.window == primary)
        }
    }

    @Test
    func `a legacy cached weekly shape cannot recreate provider evidence`() throws {
        let promoted = Self.status(isUnified: true).toUsageSnapshot(now: Self.now)
        let legacy = UsageSnapshot(
            primary: promoted.primary,
            secondary: promoted.secondary,
            tertiary: promoted.tertiary,
            updatedAt: promoted.updatedAt,
            identity: promoted.identity)
        let restoredLegacy = try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(legacy))
        for snapshot in [legacy, restoredLegacy] {
            #expect(snapshot.primary?.usedPercent == 80)
            #expect(snapshot.primary?.windowMinutes == 10080)
            #expect(CursorProviderDescriptor.sharedWeeklyPool(snapshot: snapshot) == nil)
            #expect(CursorProviderDescriptor.primaryLabel(snapshot: snapshot) == nil)
            #expect(CursorProviderDescriptor.menuBarExtras(snapshot: snapshot).isEmpty)
        }
    }

    @Test
    func `shared email and a unified plan name do not establish a shared allowance`() {
        let independent = Self.status(isUnified: false, membership: "unified").toUsageSnapshot(now: Self.now)
        let confirmed = Self.status(isUnified: true, membership: "unified").toUsageSnapshot(now: Self.now)
        #expect(independent.identity?.accountEmail == confirmed.identity?.accountEmail)
        #expect(independent.identity?.accountID == confirmed.identity?.accountID)
        #expect(independent.identity?.loginMethod == confirmed.identity?.loginMethod)
        #expect(independent.primary?.usedPercent == 20)
        #expect(confirmed.primary?.usedPercent == 80)
        #expect(CursorProviderDescriptor.sharedWeeklyPool(snapshot: independent) == nil)
        #expect(CursorProviderDescriptor.sharedWeeklyPool(snapshot: confirmed) == confirmed.primary)
    }

    @Test
    func `Cursor shared allowance evidence does not apply in Grok provider scope`() {
        let cursor = Self.status(isUnified: true).toUsageSnapshot(now: Self.now)
        let grok = cursor.scoped(to: .grok)
        #expect(grok.identity?.providerID == .grok)
        #expect(grok.primary == cursor.primary)
        #expect(CursorProviderDescriptor.sharedWeeklyPool(snapshot: grok) == nil)
        #expect(CursorProviderDescriptor.primaryLabel(snapshot: grok) == nil)
        #expect(CursorProviderDescriptor.menuBarExtras(snapshot: grok).isEmpty)
    }

    #if os(macOS)
    private enum UnexpectedFallback: Error {
        case perform
        case network
    }

    private final class AuthFallbackSpy: CursorAppAuthSessionProviding, ProviderHTTPTransport, @unchecked Sendable {
        struct Calls: Sendable {
            var appLoads = 0
            var performs = 0
            var persists = 0
            var network = 0
        }

        private let lock = NSLock()
        private let appSession: CursorAppAuthSession
        private var calls = Calls()

        init(appSession: CursorAppAuthSession) {
            self.appSession = appSession
        }

        func loadSession() throws -> CursorAppAuthSession? {
            self.lock.withLock { self.calls.appLoads += 1 }
            return self.appSession
        }

        func data(for _: URLRequest) async throws -> (Data, URLResponse) {
            self.lock.withLock { self.calls.network += 1 }
            throw UnexpectedFallback.network
        }

        func recordPerform() {
            self.lock.withLock { self.calls.performs += 1 }
        }

        func recordPersistence() {
            self.lock.withLock { self.calls.persists += 1 }
        }

        func recordedCalls() -> Calls {
            self.lock.withLock { self.calls }
        }
    }

    @Test(arguments: ["", " \t\n "])
    func `an explicitly blank manual credential cannot fall back to another account`(override: String) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CursorAccountBoundaryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let claims: [String: Any] = [
            "sub": "auth0|ambient-fixture-account",
            "email": "different-account@example.test",
            "exp": Int(Date().addingTimeInterval(3600).timeIntervalSince1970),
        ]
        let payload = try JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys])
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let appSession = CursorAppAuthSession(accessToken: "header.\(payload).signature")
        try #require(appSession.isUsable)
        let spy = AuthFallbackSpy(appSession: appSession)
        let probe = CursorStatusProbe(
            browserDetection: BrowserDetection(cacheTTL: 0),
            browserCookieImportOrder: [],
            urlSession: spy,
            appAuthStore: spy,
            sessionStore: CursorSessionStore(fileURL: root.appendingPathComponent("cursor-session.json")),
            persistAppAuthSession: { _ in spy.recordPersistence() },
            conditionalMutationCoordinator: .init())

        do {
            let _: String = try await probe.resolveSession(
                cookieHeaderOverride: override,
                allowCachedSessions: false,
                allowAppAuthFallback: true)
            { _, _ in
                spy.recordPerform()
                throw UnexpectedFallback.perform
            }
            Issue.record("Expected an explicit blank credential to fail before account fallback")
        } catch CursorStatusProbeError.noSessionCookie {
            // Selected but absent credentials are not an instruction to discover a different account.
        } catch {
            Issue.record("Expected noSessionCookie without entering an ambient account's request path")
        }
        let calls = spy.recordedCalls()
        #expect(calls.appLoads == 0)
        #expect(calls.performs == 0)
        #expect(calls.persists == 0)
        #expect(calls.network == 0)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("cursor-session.json").path))
    }
    #endif
}
