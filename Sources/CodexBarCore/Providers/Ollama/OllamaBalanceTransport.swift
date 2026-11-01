import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Process-local, credential-scoped cooldown shared by newly resolved strategies.
/// Never persists credentials or balances, and coalesces simultaneous refreshes.
actor OllamaBalanceTransport: ProviderHTTPTransport {
    static let shared = OllamaBalanceTransport()

    private struct Entry {
        let task: Task<(Data, URLResponse), Error>
        var expiresAt: Date
    }

    private let base: any ProviderHTTPTransport
    private let clock: @Sendable () -> Date
    private var entries: [String: Entry] = [:]

    init(
        base: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        clock: @escaping @Sendable () -> Date = { Date() })
    {
        self.base = base
        self.clock = clock
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await self.data(for: request, now: Date())
    }

    func data(for request: URLRequest, now: Date) async throws -> (Data, URLResponse) {
        let startedAt = self.clock()
        try Task.checkCancellation()
        guard request.url?.absoluteString == "https://ollama.com/api/balance",
              request.httpMethod == "GET",
              let authorization = request.value(forHTTPHeaderField: "Authorization")
        else { throw URLError(.badURL) }
        let key = SHA256.hash(data: Data(authorization.utf8)).map { String(format: "%02x", $0) }.joined()
        self.entries = self.entries.filter { $0.value.expiresAt > now }
        let task: Task<(Data, URLResponse), Error>
        if let entry = self.entries[key] {
            task = entry.task
        } else {
            // Bound memory without evicting an active account's cooldown.
            guard self.entries.count < 64 else {
                throw ProviderFetchClassifiedError(
                    kind: .rateLimited,
                    message: "Ollama balance refresh is cooling down.")
            }
            task = Task { try await self.base.data(for: request) }
            self.entries[key] = Entry(task: task, expiresAt: .distantFuture)
        }
        let result = await task.result
        if self.entries[key]?.expiresAt == .distantFuture {
            var cooldown: TimeInterval = 60
            if case let .success((_, response)) = result,
               let http = response as? HTTPURLResponse, http.statusCode == 429,
               let raw = http.value(forHTTPHeaderField: "Retry-After"),
               let seconds = TimeInterval(raw), seconds.isFinite, seconds >= 0
            {
                cooldown = max(cooldown, seconds)
            }
            self.entries[key]?.expiresAt = now
                .addingTimeInterval(max(0, self.clock().timeIntervalSince(startedAt)) + cooldown)
        }
        try Task.checkCancellation()
        return try result.get()
    }
}

struct OllamaBalanceFetchStrategy: ProviderFetchStrategy {
    let script: ScriptFetchStrategy
    var id: String {
        self.script.id
    }

    var kind: ProviderFetchKind {
        self.script.kind
    }

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        await self.script.isAvailable(context)
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        try await self.script.fetch(context)
    }

    func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        context.sourceMode == .auto && context.settings?.ollama?.cookieSource != .off &&
            !(error is CancellationError) && (error as? URLError)?.code != .cancelled
    }
}
