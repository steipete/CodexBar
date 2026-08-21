import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct MuseUsageFetcherTests {
    // MARK: - Balance parsing — require numeric balance

    @Test
    func `parses available_balance with usd`() throws {
        let json = """
        {"available_balance": 12.34, "currency": "usd"}
        """
        let summary = try MuseUsageFetcher.parseBalanceForTesting(Data(json.utf8))
        #expect(summary.balance == 12.34)
        #expect(summary.currency == "usd")
        #expect(summary.toUsageSnapshot().loginMethod(for: .muse) == "Balance: $12.34")
    }

    @Test
    func `parses nested data balance`() throws {
        let json = """
        {"data": {"balance": 99.5, "currency": "eur"}}
        """
        let summary = try MuseUsageFetcher.parseBalanceForTesting(Data(json.utf8))
        #expect(summary.balance == 99.5)
        #expect(summary.currency == "eur")
    }

    @Test
    func `rejects currency-only payload`() throws {
        let json = """
        {"currency": "usd"}
        """
        #expect {
            _ = try MuseUsageFetcher.parseBalanceForTesting(Data(json.utf8))
        } throws: { error in
            guard case MuseUsageError.parseFailed = error else { return false }
            return true
        }
    }

    @Test
    func `rejects empty object for balance`() throws {
        let json = "{}"
        #expect {
            _ = try MuseUsageFetcher.parseBalanceForTesting(Data(json.utf8))
        } throws: { error in
            guard case MuseUsageError.parseFailed = error else { return false }
            return true
        }
    }

    // MARK: - Models parsing — require data/models array

    @Test
    func `parses models count`() throws {
        let json = """
        {"data": [{"id": "muse-spark-1.1"}, {"id": "muse-spark-1.2"}]}
        """
        let count = try MuseUsageFetcher.parseModelsCountForTesting(Data(json.utf8))
        #expect(count == 2)
    }

    @Test
    func `rejects empty models object`() throws {
        let json = "{}"
        #expect {
            _ = try MuseUsageFetcher.parseModelsCountForTesting(Data(json.utf8))
        } throws: { error in
            guard case MuseUsageError.parseFailed = error else { return false }
            return true
        }
    }

    @Test
    func `rejects models response without array`() throws {
        let json = """
        {"object": "list"}
        """
        #expect {
            _ = try MuseUsageFetcher.parseModelsCountForTesting(Data(json.utf8))
        } throws: { error in
            guard case MuseUsageError.parseFailed = error else { return false }
            return true
        }
    }

    // MARK: - Bearer + validation + fallback

    @Test
    func `fetchUsage sends Bearer and validates https guard`() async throws {
        // Insecure http (non-localhost) must be rejected before network
        await #expect {
            _ = try await MuseUsageFetcher.fetchUsage(
                apiKey: "sk-test",
                baseURLString: "http://evil.example.com",
                session: MuseStubTransport { _ in fatalError("should not reach network") })
        } throws: { error in
            guard case let MuseUsageError.apiError(msg) = error else { return false }
            return msg.contains("Insecure base URL")
        }
    }

    @Test
    func `rejects user info in base URL`() async throws {
        await #expect {
            _ = try await MuseUsageFetcher.fetchUsage(
                apiKey: "sk-test",
                baseURLString: "https://user:pass@evil.example.com",
                session: MuseStubTransport { _ in fatalError("should not reach network") })
        } throws: { error in
            guard case let MuseUsageError.apiError(msg) = error else { return false }
            return msg.contains("Insecure base URL")
        }
    }

    @Test
    func `rejects encoded host delimiters`() async throws {
        await #expect {
            _ = try await MuseUsageFetcher.fetchUsage(
                apiKey: "sk-test",
                baseURLString: "https://evil%2Fexample.com",
                session: MuseStubTransport { _ in fatalError("should not reach network") })
        } throws: { error in
            guard case let MuseUsageError.apiError(msg) = error else { return false }
            return msg.contains("Insecure base URL")
        }
    }

    @Test
    func `rejects missing host`() async throws {
        await #expect {
            _ = try await MuseUsageFetcher.fetchUsage(
                apiKey: "sk-test",
                baseURLString: "https://",
                session: MuseStubTransport { _ in fatalError("should not reach network") })
        } throws: { error in
            guard case let MuseUsageError.apiError(msg) = error else { return false }
            return msg.contains("Insecure base URL")
        }
    }

    @Test
    func `http localhost is allowed`() async throws {
        let transport = MuseStubTransport { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            #expect(request.timeoutInterval == 15)
            let body = #"{"available_balance": 5.0, "currency": "usd"}"#
            let resp = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!
            return (resp, Data(body.utf8))
        }
        let snap = try await MuseUsageFetcher.fetchUsage(
            apiKey: "sk-test",
            baseURLString: "http://127.0.0.1:8765",
            session: transport)
        #expect(snap.summary.balance == 5.0)
    }

    @Test
    func `preserves 401 from models probe over stale billing 500`() async throws {
        let calls = CallsBox()
        let transport = MuseStubTransport { request in
            calls.increment()
            if request.url?.path.contains("/v1/billing/usage") == true {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: [:])!
                return (resp, Data())
            }
            if request.url?.path.contains("/v1/models") == true {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: [:])!
                return (resp, Data())
            }
            let resp = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: [:])!
            return (resp, Data())
        }
        await #expect {
            _ = try await MuseUsageFetcher.fetchUsage(
                apiKey: "sk-test",
                baseURLString: "https://api.meta.ai",
                session: transport)
        } throws: { error in
            guard case let MuseUsageError.apiError(msg) = error else { return false }
            return msg.contains("401")
        }
        #expect(calls.value >= 2)
    }

    @Test
    func `balance 200 is preferred over models fallback`() async throws {
        let transport = MuseStubTransport { request in
            if request.url?.path.contains("/v1/billing/usage") == true {
                let body = #"{"available_balance": 12.34, "currency": "usd"}"#
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!
                return (resp, Data(body.utf8))
            }
            // models should not be hit if billing succeeds, but stub it anyway
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!
            return (resp, Data(#"{"data":[]}"#.utf8))
        }
        let snap = try await MuseUsageFetcher.fetchUsage(
            apiKey: "sk-test",
            baseURLString: "https://api.meta.ai",
            session: transport)
        #expect(snap.summary.balance == 12.34)
    }

    @Test
    func `missing api key throws`() async throws {
        await #expect {
            _ = try await MuseUsageFetcher.fetchUsage(
                apiKey: "   ",
                baseURLString: nil,
                session: MuseStubTransport { _ in fatalError("should not reach network") })
        } throws: { error in
            guard case MuseUsageError.missingCredentials = error else { return false }
            return true
        }
    }
}

// MARK: - Stub transport (ProviderHTTPTransport)

private final class CallsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int {
        self.lock.withLock { self._value }
    }

    func increment() {
        self.lock.withLock { self._value += 1 }
    }
}

private struct MuseStubTransport: ProviderHTTPTransport {
    let handler: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    init(_ handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)) {
        self.handler = handler
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let (resp, data) = try handler(request)
        return (data, resp)
    }
}

// MARK: - Test hooks (expose private parsers)

extension MuseUsageFetcher {
    static func parseBalanceForTesting(_ data: Data) throws -> MuseUsageSummary {
        try parseBalanceResponse(data: data)
    }

    static func parseModelsCountForTesting(_ data: Data) throws -> Int? {
        try parseModelsCount(data: data)
    }
}
