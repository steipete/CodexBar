import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct ClinePassUsageStatsTests {
    private static let now = Date(timeIntervalSince1970: 1_739_841_600)

    // MARK: - Snapshot mapping

    @Test
    func `make snapshot maps window types to fields`() {
        let snap = ClinePassUsageFetcher.makeSnapshot(
            planName: "Cline Pass (Monthly)",
            accountEmail: "dev@example.com",
            limits: [
                (type: "five_hour", percentUsed: 4, resetsAt: "2026-07-04T08:06:31.278937516Z"),
                (type: "weekly", percentUsed: 6, resetsAt: "2026-07-10T19:56:51.280824586Z"),
                (type: "monthly", percentUsed: 3, resetsAt: "2026-08-02T19:56:51.282685957Z"),
            ],
            now: Self.now)

        #expect(snap.fiveHour?.percentUsed == 4)
        #expect(snap.weekly?.percentUsed == 6)
        #expect(snap.monthly?.percentUsed == 3)
        #expect(snap.fiveHour?.resetsAt != nil)
        #expect(snap.planName == "Cline Pass (Monthly)")
        #expect(snap.accountEmail == "dev@example.com")
        #expect(snap.hasWindows)
    }

    @Test
    func `make snapshot leaves missing window types nil`() {
        let snap = ClinePassUsageFetcher.makeSnapshot(
            planName: "Cline Pass (Monthly)",
            accountEmail: nil,
            limits: [(type: "five_hour", percentUsed: 10, resetsAt: nil)],
            now: Self.now)

        #expect(snap.fiveHour?.percentUsed == 10)
        #expect(snap.fiveHour?.resetsAt == nil)
        #expect(snap.weekly == nil)
        #expect(snap.monthly == nil)
        #expect(snap.hasWindows)
    }

    @Test
    func `no windows when limits are empty`() {
        let snap = ClinePassUsageFetcher.makeSnapshot(
            planName: "Free",
            accountEmail: nil,
            limits: [],
            now: Self.now)

        #expect(!snap.hasWindows)
        #expect(snap.planName == "Free")
    }

    @Test
    func `make snapshot omits window whose percent is unreported rather than showing zero`() {
        // A present row with null percentUsed means "usage not reported" — it
        // must NOT surface as 0% used / full quota.
        let snap = ClinePassUsageFetcher.makeSnapshot(
            planName: "Cline Pass (Monthly)",
            accountEmail: nil,
            limits: [
                (type: "five_hour", percentUsed: 12, resetsAt: nil),
                (type: "weekly", percentUsed: nil, resetsAt: nil),
            ],
            now: Self.now)

        #expect(snap.fiveHour?.percentUsed == 12)
        #expect(snap.weekly == nil) // null percent -> omitted, not 0%
    }

    @Test
    func `make snapshot matches window type case insensitively`() {
        let snap = ClinePassUsageFetcher.makeSnapshot(
            planName: "Cline Pass (Monthly)",
            accountEmail: nil,
            limits: [
                (type: "FIVE_HOUR", percentUsed: 4, resetsAt: nil),
                (type: "Weekly", percentUsed: 6, resetsAt: nil),
            ],
            now: Self.now)

        #expect(snap.fiveHour?.percentUsed == 4)
        #expect(snap.weekly?.percentUsed == 6)
    }

    @Test
    func `to usage snapshot maps windows to rate windows and clamps percent`() {
        let usage = ClinePassUsageFetcher.makeSnapshot(
            planName: "Cline Pass (Monthly)",
            accountEmail: "dev@example.com",
            limits: [
                (type: "five_hour", percentUsed: 120, resetsAt: nil), // clamps to 100
                (type: "weekly", percentUsed: 6, resetsAt: nil),
                (type: "monthly", percentUsed: 3, resetsAt: nil),
            ],
            now: Self.now)
            .toUsageSnapshot()

        #expect(usage.dataConfidence == .exact)
        #expect(usage.identity?.providerID == .clinepass)
        #expect(usage.identity?.accountEmail == "dev@example.com")
        #expect(usage.identity?.loginMethod == "Cline Pass (Monthly)")
        #expect(usage.primary?.windowMinutes == 300)
        #expect(usage.primary?.usedPercent == 100) // clamped
        #expect(usage.secondary?.windowMinutes == 10080)
        #expect(usage.secondary?.usedPercent == 6)
        #expect(usage.tertiary?.windowMinutes == 43200)
        #expect(usage.tertiary?.usedPercent == 3)
    }

    @Test
    func `parses iso timestamps with variable fractional seconds`() throws {
        // Cline returns high-precision fractional seconds; the parser truncates
        // them to whole seconds (adequate for reset countdowns).
        let a = try #require(ClinePassUsageFetcher.parseTimestamp("2026-07-04T08:06:31.278937516Z"))
        let b = try #require(ClinePassUsageFetcher.parseTimestamp("2026-07-04T08:06:31Z"))
        // Compare at whole-second granularity (Date equality can carry sub-second
        // float residue from the formatter across toolchains).
        #expect(Int(a.timeIntervalSince1970) == Int(b.timeIntervalSince1970))
        #expect(Int(a.timeIntervalSince1970) == 1_783_152_391)
    }

    // MARK: - Full fetch flow

    @Test
    func `fetch usage reads user plan and limits`() async throws {
        let transport = ProviderHTTPTransportHandler { request in
            guard let url = request.url else { throw URLError(.badURL) }
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer cline-test")
            switch url.path {
            case "/api/v1/users/me":
                return Self.ok(url, #"{"success":true,"data":{"id":"user-1","email":"dev@example.com"}}"#)
            case "/api/v1/users/me/plan":
                return Self.ok(url, #"{"success":true,"data":{"plan":{"displayName":"Cline Pass (Monthly)"}}}"#)
            case "/api/v1/users/me/plan/usage-limits":
                return Self.ok(url, """
                {"success":true,"data":{"limits":[
                {"type":"five_hour","percentUsed":4,"resetsAt":"2026-07-04T08:06:31.27Z"},
                {"type":"weekly","percentUsed":6,"resetsAt":"2026-07-10T19:56:51.28Z"},
                {"type":"monthly","percentUsed":3,"resetsAt":"2026-08-02T19:56:51.28Z"}]}}
                """)
            default:
                Issue.record("Unexpected path: \(url.path)")
                throw URLError(.badURL)
            }
        }

        let usage = try await ClinePassUsageFetcher.fetchUsage(
            apiKey: "cline-test",
            environment: ["CLINE_API_BASE_URL": "https://cline.test"],
            transport: transport,
            now: Self.now)

        #expect(usage.planName == "Cline Pass (Monthly)")
        #expect(usage.accountEmail == "dev@example.com")
        #expect(usage.fiveHour?.percentUsed == 4)
        #expect(usage.weekly?.percentUsed == 6)
        #expect(usage.monthly?.percentUsed == 3)
    }

    @Test
    func `fetch usage handles empty limits`() async throws {
        let transport = ProviderHTTPTransportHandler { request in
            guard let url = request.url else { throw URLError(.badURL) }
            switch url.path {
            case "/api/v1/users/me":
                return Self.ok(url, #"{"success":true,"data":{"id":"user-1","email":"dev@example.com"}}"#)
            case "/api/v1/users/me/plan":
                return Self.ok(url, #"{"success":true,"data":{"plan":{"displayName":"Free"}}}"#)
            case "/api/v1/users/me/plan/usage-limits":
                return Self.ok(url, #"{"success":true,"data":{"limits":[]}}"#)
            default:
                throw URLError(.badURL)
            }
        }

        let usage = try await ClinePassUsageFetcher.fetchUsage(
            apiKey: "cline-test",
            environment: ["CLINE_API_BASE_URL": "https://cline.test"],
            transport: transport,
            now: Self.now)

        #expect(!usage.hasWindows)
        #expect(usage.planName == "Free")
    }

    @Test
    func `fetch usage propagates cancellation from the best-effort limits request`() async throws {
        // The user/plan reads succeed, but the best-effort limits read is
        // cancelled — cancellation must propagate, not degrade to a partial
        // (plan + email only) success snapshot.
        let transport = ProviderHTTPTransportHandler { request in
            guard let url = request.url else { throw URLError(.badURL) }
            switch url.path {
            case "/api/v1/users/me":
                return Self.ok(url, #"{"success":true,"data":{"id":"user-1","email":"dev@example.com"}}"#)
            case "/api/v1/users/me/plan":
                return Self.ok(url, #"{"success":true,"data":{"plan":{"displayName":"Cline Pass (Monthly)"}}}"#)
            default:
                throw CancellationError()
            }
        }

        await #expect(throws: CancellationError.self) {
            _ = try await ClinePassUsageFetcher.fetchUsage(
                apiKey: "cline-test",
                environment: ["CLINE_API_BASE_URL": "https://cline.test"],
                transport: transport,
                now: Self.now)
        }
    }

    @Test
    func `fetch usage maps url session cancellation from the best-effort limits request`() async throws {
        let transport = ProviderHTTPTransportHandler { request in
            guard let url = request.url else { throw URLError(.badURL) }
            switch url.path {
            case "/api/v1/users/me":
                return Self.ok(url, #"{"success":true,"data":{"id":"user-1","email":"dev@example.com"}}"#)
            case "/api/v1/users/me/plan":
                return Self.ok(url, #"{"success":true,"data":{"plan":{"displayName":"Cline Pass (Monthly)"}}}"#)
            default:
                throw URLError(.cancelled)
            }
        }

        await #expect(throws: CancellationError.self) {
            _ = try await ClinePassUsageFetcher.fetchUsage(
                apiKey: "cline-test",
                environment: ["CLINE_API_BASE_URL": "https://cline.test"],
                transport: transport,
                now: Self.now)
        }
    }

    @Test
    func `fetch usage cancelled in-flight surfaces cancellation even when limits fails generically`() async throws {
        // The realistic case the earlier synchronous tests don't cover: the
        // parent refresh is cancelled while /plan/usage-limits is still in
        // flight, and URLSession then reports a GENERIC error (not
        // CancellationError / URLError.cancelled). The `Task.isCancelled` guard
        // must still surface this as a cancelled refresh, never a partial
        // (plan + email) success snapshot.
        let gate = ClinePassCancelGate()
        let transport = ProviderHTTPTransportHandler { request in
            guard let url = request.url else { throw URLError(.badURL) }
            switch url.path {
            case "/api/v1/users/me":
                return Self.ok(url, #"{"success":true,"data":{"id":"user-1","email":"dev@example.com"}}"#)
            case "/api/v1/users/me/plan":
                return Self.ok(url, #"{"success":true,"data":{"plan":{"displayName":"Cline Pass (Monthly)"}}}"#)
            default:
                // Announce the limits request is in flight, then wait for the
                // parent task to be cancelled and fail with a generic error.
                await gate.markInFlight()
                var spins = 0
                while !Task.isCancelled, spins < 5000 {
                    try? await Task.sleep(nanoseconds: 1_000_000)
                    spins += 1
                }
                throw URLError(.timedOut)
            }
        }

        let task = Task {
            try await ClinePassUsageFetcher.fetchUsage(
                apiKey: "cline-test",
                environment: ["CLINE_API_BASE_URL": "https://cline.test"],
                transport: transport,
                now: Self.now)
        }

        await gate.waitUntilInFlight()
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    @Test
    func `normalized base path strips version segment and trailing slash`() {
        // No path / bare host.
        #expect(ClinePassUsageFetcher.normalizedBasePath("") == "")
        // Trailing slash only.
        #expect(ClinePassUsageFetcher.normalizedBasePath("/") == "")
        // Cline's documented versioned root — the version must be normalized out
        // so the endpoint suffix does not double it.
        #expect(ClinePassUsageFetcher.normalizedBasePath("/api/v1") == "")
        #expect(ClinePassUsageFetcher.normalizedBasePath("/api/v1/") == "")
        #expect(ClinePassUsageFetcher.normalizedBasePath("/API/V1") == "")
        // Host-level base path is preserved (e.g. a reverse proxy prefix).
        #expect(ClinePassUsageFetcher.normalizedBasePath("/gateway") == "/gateway")
        #expect(ClinePassUsageFetcher.normalizedBasePath("/gateway/api/v1") == "/gateway")
    }

    @Test
    func `fetch usage does not double the version segment for a versioned base url`() async throws {
        // A user following Cline's docs sets the base to the versioned API root.
        // All reads must still hit a single /api/v1 prefix, not /api/v1/api/v1.
        let seenPaths = ClinePassPathRecorder()
        let transport = ProviderHTTPTransportHandler { request in
            guard let url = request.url else { throw URLError(.badURL) }
            seenPaths.append(url.path)
            switch url.path {
            case "/api/v1/users/me":
                return Self.ok(url, #"{"success":true,"data":{"id":"user-1","email":"dev@example.com"}}"#)
            case "/api/v1/users/me/plan":
                return Self.ok(url, #"{"success":true,"data":{"plan":{"displayName":"Cline Pass (Monthly)"}}}"#)
            case "/api/v1/users/me/plan/usage-limits":
                return Self.ok(url, #"{"success":true,"data":{"limits":[]}}"#)
            default:
                Issue.record("Unexpected (possibly doubled) path: \(url.path)")
                throw URLError(.badURL)
            }
        }

        let usage = try await ClinePassUsageFetcher.fetchUsage(
            apiKey: "cline-test",
            environment: ["CLINE_API_BASE_URL": "https://cline.test/api/v1"],
            transport: transport,
            now: Self.now)

        #expect(usage.planName == "Cline Pass (Monthly)")
        #expect(!seenPaths.snapshot().contains { $0.contains("/api/v1/api/v1") })
    }

    @Test
    func `fetch usage throws invalid credentials on 401`() async throws {
        let transport = ProviderHTTPTransportHandler { request in
            guard let url = request.url else { throw URLError(.badURL) }
            return Self.ok(url, #"{"success":false,"error":"Invalid API key."}"#, statusCode: 401)
        }

        await #expect(throws: ClinePassUsageError.invalidCredentials) {
            _ = try await ClinePassUsageFetcher.fetchUsage(
                apiKey: "cline-bogus",
                environment: ["CLINE_API_BASE_URL": "https://cline.test"],
                transport: transport,
                now: Self.now)
        }
    }

    @Test
    func `fetch usage surfaces envelope error on unsuccessful payload`() async throws {
        let transport = ProviderHTTPTransportHandler { request in
            guard let url = request.url else { throw URLError(.badURL) }
            return Self.ok(url, #"{"success":false,"error":"account suspended"}"#)
        }

        await #expect(throws: ClinePassUsageError.apiError("account suspended")) {
            _ = try await ClinePassUsageFetcher.fetchUsage(
                apiKey: "cline-test",
                environment: ["CLINE_API_BASE_URL": "https://cline.test"],
                transport: transport,
                now: Self.now)
        }
    }

    @Test
    func `fetch usage rejects unsafe endpoint override before attaching credentials`() async throws {
        await #expect(throws: ClinePassSettingsError.invalidEndpointOverride("CLINE_API_BASE_URL")) {
            _ = try await ClinePassUsageFetcher.fetchUsage(
                apiKey: "cline-test",
                environment: ["CLINE_API_BASE_URL": "http://api.cline.bot"],
                transport: ProviderHTTPTransportHandler { _ in
                    Issue.record("Transport must not be called for invalid endpoint override")
                    throw URLError(.badURL)
                },
                now: Self.now)
        }
    }

    @Test
    func `fetch usage rejects cross origin redirect`() async throws {
        let transport = ProviderHTTPTransportHandler { _ in
            let redirectedURL = URL(string: "https://evil.example/api/v1/users/me")!
            return Self.ok(redirectedURL, #"{"success":true,"data":{"id":"user-1","email":"x@y.com"}}"#)
        }

        await #expect(throws: ClinePassUsageError.apiError("ClinePass /users/me redirected to a different origin")) {
            _ = try await ClinePassUsageFetcher.fetchUsage(
                apiKey: "cline-test",
                environment: ["CLINE_API_BASE_URL": "https://cline.test"],
                transport: transport,
                now: Self.now)
        }
    }

    @Test
    func `sanitizer redacts bearer tokens`() {
        let body = #"{"error":"bad","authorization":"Bearer sk-abc123"}"#
        let summary = ClinePassUsageFetcher._sanitizedResponseBodySummaryForTesting(body)
        #expect(!summary.contains("sk-abc123"))
        #expect(summary.contains("[REDACTED]"))
    }

    @Test
    func `usage snapshot round trips through codable`() throws {
        let snapshot = ClinePassUsageFetcher.makeSnapshot(
            planName: "Cline Pass (Monthly)",
            accountEmail: "dev@example.com",
            limits: [
                (type: "five_hour", percentUsed: 4, resetsAt: "2026-07-04T08:06:31Z"),
                (type: "monthly", percentUsed: 3, resetsAt: "2026-08-02T19:56:51Z"),
            ],
            now: Self.now)
            .toUsageSnapshot()

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: data)

        #expect(decoded.clinePassUsage?.fiveHour?.percentUsed == 4)
        #expect(decoded.clinePassUsage?.monthly?.percentUsed == 3)
        #expect(decoded.clinePassUsage?.planName == "Cline Pass (Monthly)")
        #expect(decoded.identity?.loginMethod == "Cline Pass (Monthly)")
    }

    // MARK: - Helpers

    private static func ok(_ url: URL, _ body: String, statusCode: Int = 200) -> (Data, URLResponse) {
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        return (Data(body.utf8), response)
    }
}

/// Thread-safe recorder for request paths seen by a stub transport.
private final class ClinePassPathRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []

    func append(_ path: String) {
        self.lock.withLock { self.paths.append(path) }
    }

    func snapshot() -> [String] {
        self.lock.withLock { self.paths }
    }
}

/// Coordinates a test that must cancel a refresh only once the best-effort
/// request is genuinely in flight, avoiding a race between cancel and dispatch.
private actor ClinePassCancelGate {
    private var inFlight = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func markInFlight() {
        self.inFlight = true
        let pending = self.waiters
        self.waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }

    func waitUntilInFlight() async {
        if self.inFlight { return }
        await withCheckedContinuation { continuation in
            if self.inFlight {
                continuation.resume()
            } else {
                self.waiters.append(continuation)
            }
        }
    }
}
