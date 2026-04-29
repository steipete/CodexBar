import Foundation

// MARK: - OpenClaw Export Format v2

/// OpenClaw-compatible export format. This is the bridge between CodexBar
/// and OpenClaw's gateway config. Supports ALL provider types.
public struct OpenClawExport: Codable, Sendable {
    public let format: String           // Always "openclaw"
    public let version: Int             // Schema version (2 = multi-provider)
    public let timestamp: String        // ISO 8601
    public let codexbarVersion: String
    public let providers: [String: OpenClawProviderExport]
    public let aliases: [String: String]
    public let fallbacks: [String]
    public let primary: String
    public let accounts: [OpenClawAccountExport]
    public let allowlist: [String]
    public let authProfiles: [String: OpenClawAuthProfileExport]
    public let plugins: [String: OpenClawPluginExport]
    public let authOrder: [String: [String]]
    public let authCooldowns: OpenClawAuthCooldownsExport
}

public struct OpenClawProviderExport: Codable, Sendable {
    public let api: String
    public let baseUrl: String
    public let apiKey: String?
    public let models: [OpenClawModelExport]
}

public struct OpenClawModelExport: Codable, Sendable {
    public let id: String
    public let name: String
    public let reasoning: Bool
    public let input: [String]
    public let cost: OpenClawCostExport
    public let contextWindow: Int
    public let maxTokens: Int
}

public struct OpenClawCostExport: Codable, Sendable {
    public let input: Double
    public let output: Double
    public let cacheRead: Double
    public let cacheWrite: Double
}

public struct OpenClawAccountExport: Codable, Sendable {
    public let email: String
    public let accountId: String
    public let provider: String
}

/// Auth profile for injection into OpenClaw's auth-profiles.json
public struct OpenClawAuthProfileExport: Codable, Sendable {
    public let type: String       // "api_key" | "oauth" | "token"
    public let provider: String   // "anthropic", "google", "ollama", etc.
    public let key: String?       // For api_key type
    public let mode: String?      // For openclaw.json auth section
}

/// Plugin to enable in OpenClaw
public struct OpenClawPluginExport: Codable, Sendable {
    public let enabled: Bool
}

/// Auth cooldown settings for account rotation
public struct OpenClawAuthCooldownsExport: Codable, Sendable {
    public let billingBackoffHours: Double
    public let authPermanentBackoffMinutes: Int
}

// MARK: - Known Cloud Provider Models

/// Static model catalogs for cloud providers (context windows are known)
private enum CloudModels {

    static let anthropic: [OpenClawModelExport] = [
        makeModel(id: "claude-opus-4-6", name: "Claude Opus 4.6", reasoning: true, input: ["text", "image"],
                  cost: (0.003, 0.015, 0.0003, 0.0015), ctx: 200_000, maxTok: 32_768),
        makeModel(id: "claude-sonnet-4-6", name: "Claude Sonnet 4.6", reasoning: true, input: ["text", "image"],
                  cost: (0.003, 0.015, 0.0003, 0.0015), ctx: 200_000, maxTok: 16_384),
        makeModel(id: "claude-haiku-3-5", name: "Claude Haiku 3.5", reasoning: false, input: ["text", "image"],
                  cost: (0.0008, 0.004, 0.00008, 0.0004), ctx: 200_000, maxTok: 8_192),
    ]

    static let google: [OpenClawModelExport] = [
        makeModel(id: "gemini-2.5-pro", name: "Gemini 2.5 Pro", reasoning: true, input: ["text", "image"],
                  cost: (0.00125, 0.01, 0.000315, 0.00125), ctx: 1_000_000, maxTok: 65_536),
        makeModel(id: "gemini-2.5-flash", name: "Gemini 2.5 Flash", reasoning: false, input: ["text", "image"],
                  cost: (0.000075, 0.0003, 0.0000225, 0.00009), ctx: 1_000_000, maxTok: 65_536),
        makeModel(id: "gemini-3-flash-preview", name: "Gemini 3 Flash", reasoning: false, input: ["text", "image"],
                  cost: (0.000075, 0.0003, 0.0000225, 0.00009), ctx: 1_000_000, maxTok: 16_384),
    ]

    static let codex: [OpenClawModelExport] = [
        makeModel(id: "gpt-5.4", name: "GPT-5.4", reasoning: true, input: ["text", "image"],
                  cost: (0.006, 0.024, 0.0009, 0.003), ctx: 1_049_000, maxTok: 32_768),
        makeModel(id: "gpt-5.2-codex", name: "GPT-5.2 Codex", reasoning: true, input: ["text", "image"],
                  cost: (0.003, 0.015, 0.0009, 0.003), ctx: 266_000, maxTok: 16_384),
        makeModel(id: "gpt-5.3-codex", name: "GPT-5.3 Codex", reasoning: true, input: ["text", "image"],
                  cost: (0.003, 0.015, 0.0009, 0.003), ctx: 266_000, maxTok: 16_384),
    ]

    private static func makeModel(
        id: String, name: String, reasoning: Bool, input: [String],
        cost: (Double, Double, Double, Double), ctx: Int, maxTok: Int
    ) -> OpenClawModelExport {
        OpenClawModelExport(
            id: id, name: name, reasoning: reasoning, input: input,
            cost: OpenClawCostExport(input: cost.0, output: cost.1, cacheRead: cost.2, cacheWrite: cost.3),
            contextWindow: ctx, maxTokens: maxTok)
    }
}

// MARK: - Exporter

/// Builds an OpenClaw-compatible export from CodexBar's current state.
/// Supports ALL provider types: Codex, Claude, Gemini, Ollama, HTTPS LMs.
public final class OpenClawExporter: Sendable {

    public init() {}

    /// Generate a full multi-provider OpenClaw export.
    public func export(
        ollamaResults: [OllamaLocalProbeResult] = [],
        codexAccounts: [CodexAccountInfo] = [],
        claudeAPIKey: String? = nil,
        geminiAPIKey: String? = nil,
        httpsLMEndpoints: [HttpsLMEndpoint] = [],
        fallbackOrder: [String]? = nil,
        primaryModel: String = "openai-codex/gpt-5.4",
        codexbarVersion: String = "0.21"
    ) -> OpenClawExport {

        var providers: [String: OpenClawProviderExport] = [:]
        var fallbacks: [String] = []
        var accounts: [OpenClawAccountExport] = []
        var authProfiles: [String: OpenClawAuthProfileExport] = [:]
        var plugins: [String: OpenClawPluginExport] = [:]
        var aliases: [String: String] = ["gpt54": "openai-codex/gpt-5.4"]

        // ─── CODEX ACCOUNTS ───
        for account in codexAccounts {
            accounts.append(OpenClawAccountExport(
                email: account.email,
                accountId: account.accountId,
                provider: "openai-codex"))
        }
        // Codex is built-in — no provider entry needed, just auth stubs
        for account in codexAccounts {
            let key = "openai-codex:codexbar-\(String(account.accountId.prefix(8)))"
            authProfiles[key] = OpenClawAuthProfileExport(
                type: "oauth", provider: "openai-codex", key: nil, mode: "oauth")
        }

        // ─── CLAUDE / ANTHROPIC ───
        if let apiKey = claudeAPIKey, !apiKey.isEmpty {
            // Anthropic is built-in — no provider entry needed
            authProfiles["anthropic:default"] = OpenClawAuthProfileExport(
                type: "api_key", provider: "anthropic", key: apiKey, mode: "api_key")
            plugins["anthropic"] = OpenClawPluginExport(enabled: true)
        }

        // ─── GEMINI / GOOGLE ───
        if let apiKey = geminiAPIKey, !apiKey.isEmpty {
            // Google is built-in — no provider entry needed
            authProfiles["google:default"] = OpenClawAuthProfileExport(
                type: "api_key", provider: "google", key: apiKey, mode: "api_key")
        }

        // ─── OLLAMA ───
        // Read master fallback order for filtering
        let masterPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codexbar/openclaw-providers.json")
        var masterFallbacks: Set<String> = []
        if let data = try? Data(contentsOf: masterPath),
           let master = try? JSONDecoder().decode(MasterProviderConfig.self, from: data)
        {
            for fb in master.fallbackOrder { masterFallbacks.insert(fb) }
            if let p = master.primary { masterFallbacks.insert(p) }
        }

        for result in ollamaResults where result.isOnline {
            let key = ollamaProviderKey(for: result.endpoint)

            let chatModels = result.models.filter { model in
                if model.isEmbedding { return false }
                if masterFallbacks.isEmpty { return true }
                return masterFallbacks.contains("\(key)/\(model.name)")
            }

            let models = chatModels.map { model in
                OpenClawModelExport(
                    id: model.name,
                    name: Self.humanReadableName(for: model),
                    reasoning: model.isReasoning,
                    input: ["text"],
                    cost: OpenClawCostExport(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
                    contextWindow: model.contextLength,
                    maxTokens: 8192)
            }

            providers[key] = OpenClawProviderExport(
                api: "ollama", baseUrl: result.endpoint.url, apiKey: "ollama-local", models: models)

            authProfiles["\(key):default"] = OpenClawAuthProfileExport(
                type: "api_key", provider: key, key: "ollama-local", mode: "api_key")

            plugins["ollama"] = OpenClawPluginExport(enabled: true)
        }

        // ─── HTTPS LMs ───
        for endpoint in httpsLMEndpoints where endpoint.isOnline {
            providers[endpoint.providerName] = OpenClawProviderExport(
                api: "openai-completions",
                baseUrl: endpoint.baseUrl,
                apiKey: endpoint.apiKey ?? "local",
                models: endpoint.models.map { model in
                    OpenClawModelExport(
                        id: model.id, name: model.name, reasoning: false,
                        input: ["text"],
                        cost: OpenClawCostExport(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
                        contextWindow: model.contextWindow, maxTokens: 8192)
                })

            authProfiles["\(endpoint.providerName):default"] = OpenClawAuthProfileExport(
                type: "api_key", provider: endpoint.providerName,
                key: endpoint.apiKey ?? "local", mode: "api_key")
        }

        // ─── FALLBACK CHAIN ───
        if let customOrder = fallbackOrder {
            fallbacks = customOrder
        } else if let data = try? Data(contentsOf: masterPath),
                  let master = try? JSONDecoder().decode(MasterProviderConfig.self, from: data),
                  !master.fallbackOrder.isEmpty
        {
            fallbacks = master.fallbackOrder
        } else {
            // Auto-build: codex → claude → gemini → ollama → https
            fallbacks = [primaryModel]
            if claudeAPIKey != nil { fallbacks.append("anthropic/claude-opus-4-6") }
            if geminiAPIKey != nil { fallbacks.append("google/gemini-2.5-pro") }
            for (key, prov) in providers {
                for model in prov.models {
                    let ref = "\(key)/\(model.id)"
                    if !fallbacks.contains(ref) { fallbacks.append(ref) }
                }
            }
        }

        // ─── ALLOWLIST ───
        var allowlist: [String] = []
        allowlist.append(primaryModel)
        for fb in fallbacks where fb != primaryModel { allowlist.append(fb) }

        // ─── AUTH ORDER — Codex account rotation ───
        var authOrder: [String: [String]] = [:]
        let codexProfileKeys = authProfiles.keys
            .filter { $0.hasPrefix("openai-codex:") }
            .sorted()
        if codexProfileKeys.count > 1 {
            authOrder["openai-codex"] = codexProfileKeys
        }

        // ─── AUTH COOLDOWNS — fast rotation for multi-account ───
        let authCooldowns = OpenClawAuthCooldownsExport(
            billingBackoffHours: 0.08,  // ~5 minutes
            authPermanentBackoffMinutes: 2)

        return OpenClawExport(
            format: "openclaw", version: 2,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            codexbarVersion: codexbarVersion,
            providers: providers,
            aliases: aliases,
            fallbacks: fallbacks,
            primary: primaryModel,
            accounts: accounts,
            allowlist: allowlist,
            authProfiles: authProfiles,
            plugins: plugins,
            authOrder: authOrder,
            authCooldowns: authCooldowns)
    }

    /// Convert export to JSON string.
    public func exportJSON(
        ollamaResults: [OllamaLocalProbeResult] = [],
        codexAccounts: [CodexAccountInfo] = [],
        claudeAPIKey: String? = nil,
        geminiAPIKey: String? = nil,
        httpsLMEndpoints: [HttpsLMEndpoint] = [],
        fallbackOrder: [String]? = nil,
        primaryModel: String = "openai-codex/gpt-5.4",
        codexbarVersion: String = "0.21"
    ) -> String {
        let export = self.export(
            ollamaResults: ollamaResults,
            codexAccounts: codexAccounts,
            claudeAPIKey: claudeAPIKey,
            geminiAPIKey: geminiAPIKey,
            httpsLMEndpoints: httpsLMEndpoints,
            fallbackOrder: fallbackOrder,
            primaryModel: primaryModel,
            codexbarVersion: codexbarVersion)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(export) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: - Helpers

    /// Generate a clear, human-readable display name from an Ollama model.
    private static func humanReadableName(for model: OllamaLocalModel) -> String {
        let id = model.name
        let size = model.sizeLabel

        let knownNames: [String: String] = [
            "gemma4:e4b": "Gemma 4 E4B",
            "gemma3:27b": "Gemma 3 27B",
            "gemma3:12b": "Gemma 3 12B",
            "gpt-oss:20b": "GPT-OSS 20B",
            "qwen3-coder:30b": "Qwen3 Coder 30B",
            "qwen25coder7b:latest": "Qwen 2.5 Coder 7B",
            "gemma426b:latest": "Gemma 4 26B",
            "gemma3-12b-qat-q4km-local:latest": "Gemma 3 12B Q4KM",
            "gemma3-12b-qat-q3kl-local:latest": "Gemma 3 12B Q3KL",
            "devstral:24b": "Devstral 24B",
        ]

        if let known = knownNames[id] { return "\(known) (\(size))" }

        let base = id
            .replacingOccurrences(of: ":latest", with: "")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: ":", with: " ")
        let capitalized = base.split(separator: " ").map { word in
            let w = String(word)
            if w.last == "b", let _ = Int(String(w.dropLast())) { return w.uppercased() }
            return w.prefix(1).uppercased() + w.dropFirst()
        }.joined(separator: " ")

        return "\(capitalized) (\(size))"
    }

    private func ollamaProviderKey(for endpoint: OllamaLocalEndpoint) -> String {
        switch endpoint.type {
        case .local: return "ollama"
        case .lan: return "ollama-lan"
        case .remote: return "ollama-remote"
        }
    }
}

// MARK: - HTTPS LM Endpoint

/// Discovered HTTPS LM endpoint (LM Studio, vLLM, llama.cpp, etc.)
public struct HttpsLMEndpoint: Sendable {
    public let providerName: String
    public let baseUrl: String
    public let apiKey: String?
    public let isOnline: Bool
    public let models: [HttpsLMModel]

    public init(providerName: String, baseUrl: String, apiKey: String?, isOnline: Bool, models: [HttpsLMModel]) {
        self.providerName = providerName
        self.baseUrl = baseUrl
        self.apiKey = apiKey
        self.isOnline = isOnline
        self.models = models
    }
}

public struct HttpsLMModel: Sendable {
    public let id: String
    public let name: String
    public let contextWindow: Int

    public init(id: String, name: String, contextWindow: Int = 32768) {
        self.id = id
        self.name = name
        self.contextWindow = contextWindow
    }
}

// MARK: - Codex Account Info

public struct CodexAccountInfo: Codable, Sendable {
    public let email: String
    public let accountId: String

    public init(email: String, accountId: String) {
        self.email = email
        self.accountId = accountId
    }

    /// Read ALL Codex accounts — both CodexBar managed homes and system Codex auth.
    public static func loadManagedAccounts() -> [CodexAccountInfo] {
        var accounts: [CodexAccountInfo] = []
        var seenAccountIds: Set<String> = []

        let managedPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexBar/managed-codex-accounts.json")
        if let data = try? Data(contentsOf: managedPath),
           let wrapper = try? JSONDecoder().decode(ManagedAccountSet.self, from: data)
        {
            for acct in wrapper.accounts {
                accounts.append(CodexAccountInfo(email: acct.email, accountId: acct.providerAccountID))
                seenAccountIds.insert(acct.providerAccountID)
            }
        }

        let codexAuthPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
        if let data = try? Data(contentsOf: codexAuthPath),
           let auth = try? JSONDecoder().decode(CodexCLIAuth.self, from: data),
           let accountId = auth.tokens?.account_id,
           !accountId.isEmpty,
           !seenAccountIds.contains(accountId)
        {
            let email: String
            if let idToken = auth.tokens?.id_token {
                let parts = idToken.split(separator: ".")
                if parts.count >= 2,
                   let decoded = Data(base64Encoded: String(parts[1]) + "=="),
                   let jwt = try? JSONSerialization.jsonObject(with: decoded) as? [String: Any],
                   let jwtEmail = jwt["email"] as? String
                { email = jwtEmail } else { email = "codex-default" }
            } else { email = "codex-default" }
            accounts.append(CodexAccountInfo(email: email, accountId: accountId))
        }

        return accounts
    }
}

// MARK: - Supporting Decodable Types

private struct ManagedAccountSet: Codable {
    let version: Int
    let accounts: [ManagedAccount]
}

private struct ManagedAccount: Codable {
    let email: String
    let providerAccountID: String
}

private struct CodexCLIAuth: Codable {
    let tokens: CodexCLITokens?
}

private struct CodexCLITokens: Codable {
    let account_id: String?
    let id_token: String?
}

private struct MasterProviderConfig: Codable {
    let fallbackOrder: [String]
    let primary: String?
}
