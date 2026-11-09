import Foundation
import Testing
@testable import CodexBarCore

struct MiniMaxTokenContextMemoTests {
    @Test
    func `cached and multiple browser candidates load one shared context per domain`() async throws {
        let cached = self.session(domain: .legacyChina, label: "Cached Profile")
        let browsers = [
            self.session(domain: .legacyChina, label: "Browser First"),
            self.session(domain: .legacyChina, label: "Browser Last"),
        ]
        var memo = MiniMaxCodingPlanFetchStrategy.TokenContextMemo<[String]>()
        var loaded: [MiniMaxWebSessionDomain] = []
        var fetched: [String] = []

        _ = try await MiniMaxCodingPlanFetchStrategy.fetchAutomatic(
            cached: [cached],
            fetchSession: { session in
                let context = memo.value(for: session, cookieOnly: [], load: { domain in
                    loaded.append(domain)
                    return ["Cached Profile", "Browser First", "Browser Last"]
                })
                #expect(context.contains(session.sourceLabel))
                fetched.append(session.sourceLabel)
                if session.sourceLabel != "Browser Last" { throw MiniMaxUsageError.invalidCredentials }
                return Self.snapshot
            },
            browserSessions: { AnySequence(browsers) },
            clearCached: { _ in },
            storeResolved: { _ in })

        #expect(loaded == [.legacyChina])
        #expect(fetched == ["Cached Profile", "Browser First", "Browser Last"])
    }

    @Test
    func `each session domain retains its own loaded context`() {
        var memo = MiniMaxCodingPlanFetchStrategy.TokenContextMemo<String>()
        var loads: [MiniMaxWebSessionDomain: Int] = [:]

        for _ in 0..<2 {
            for domain in MiniMaxWebSessionDomain.allCases {
                let context = memo.value(for: self.session(domain: domain), cookieOnly: "cookie-only", load: { domain in
                    loads[domain, default: 0] += 1
                    return domain.rawValue
                })
                #expect(context == domain.rawValue)
            }
        }
        #expect(loads == [.global: 1, .chinaMainland: 1, .legacyChina: 1])
    }

    @Test
    func `current China token cookies never read browser storage`() {
        var memo = MiniMaxCodingPlanFetchStrategy.TokenContextMemo<[String]>()
        var loads = 0
        let session = self.session(domain: .chinaMainland, cookie: "_token=current-fixture")

        for _ in 0..<3 {
            let context = memo.value(for: session, cookieOnly: [], load: { _ in
                loads += 1
                return ["storage"]
            })
            #expect(context.isEmpty)
        }
        #expect(loads == 0)
    }

    @Test(arguments: [false, true])
    func `cookie only and storage candidates cannot poison each other`(cookieFirst: Bool) {
        var memo = MiniMaxCodingPlanFetchStrategy.TokenContextMemo<String>()
        var loads = 0
        let cookie = self.session(domain: .chinaMainland, cookie: "_token=current-fixture")
        let storage = self.session(domain: .chinaMainland)
        let sessions = cookieFirst ? [cookie, storage, cookie] : [storage, cookie, storage]

        for session in sessions {
            let context = memo.value(for: session, cookieOnly: "cookie-only", load: { _ in
                loads += 1
                return "storage"
            })
            #expect(context == (session.usesTokenCookie ? "cookie-only" : "storage"))
        }
        #expect(loads == 1)
    }

    @Test(arguments: [MiniMaxWebSessionDomain.global, .legacyChina])
    func `token cookies in other realms retain storage fallback`(domain: MiniMaxWebSessionDomain) {
        var memo = MiniMaxCodingPlanFetchStrategy.TokenContextMemo<String>()
        var loads = 0

        let context = memo.value(
            for: self.session(domain: domain, cookie: "_token=other-product-fixture"),
            cookieOnly: "cookie-only",
            load: { _ in
                loads += 1
                return "storage"
            })

        #expect(context == "storage")
        #expect(loads == 1)
    }

    @Test
    func `empty storage results are reused across same domain candidates`() {
        var memo = MiniMaxCodingPlanFetchStrategy.TokenContextMemo<[String]>()
        var loads = 0

        for label in ["First Profile", "Second Profile", "Third Profile"] {
            let context = memo.value(for: self.session(domain: .global, label: label), cookieOnly: [], load: { _ in
                loads += 1
                return []
            })
            #expect(context.isEmpty)
        }
        #expect(loads == 1)
    }

    @Test
    func `separate refresh instances observe fresh storage independently`() {
        var firstRefresh = MiniMaxCodingPlanFetchStrategy.TokenContextMemo<Int>()
        var secondRefresh = MiniMaxCodingPlanFetchStrategy.TokenContextMemo<Int>()
        var loads = 0
        let session = self.session(domain: .legacyChina)
        let load: (MiniMaxWebSessionDomain) -> Int = { _ in
            loads += 1
            return loads
        }

        #expect(firstRefresh.value(for: session, cookieOnly: 0, load: load) == 1)
        #expect(secondRefresh.value(for: session, cookieOnly: 0, load: load) == 2)
        #expect(firstRefresh.value(for: session, cookieOnly: 0, load: load) == 1)
        #expect(loads == 2)
    }

    private func session(
        domain: MiniMaxWebSessionDomain,
        label: String = "Fixture Profile",
        cookie: String = "HERTZ-SESSION=fixture") -> MiniMaxWebSession
    {
        MiniMaxWebSession(cookieHeader: cookie, sourceLabel: label, domain: domain)
    }

    private static let snapshot = MiniMaxUsageSnapshot(
        planName: nil,
        availablePrompts: nil,
        currentPrompts: nil,
        remainingPrompts: nil,
        windowMinutes: 300,
        usedPercent: 23,
        resetsAt: nil,
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
}
