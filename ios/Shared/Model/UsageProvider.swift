import Foundation

/// iOS-safe mirror of `CodexBarCore.UsageProvider`. Raw values MUST match the macOS enum
/// exactly so snapshot JSON decodes across platforms.
public enum UsageProvider: String, CaseIterable, Sendable, Codable, Hashable {
    case codex
    case openai
    case azureopenai
    case claude
    case cursor
    case opencode
    case opencodego
    case alibaba
    case alibabatokenplan
    case factory
    case gemini
    case antigravity
    case copilot
    case devin
    case zai
    case minimax
    case manus
    case kimi
    case kilo
    case kiro
    case vertexai
    case augment
    case jetbrains
    case kimik2
    case moonshot
    case amp
    case t3chat
    case ollama
    case synthetic
    case warp
    case openrouter
    case elevenlabs
    case windsurf
    case zed
    case perplexity
    case mimo
    case doubao
    case sakana
    case abacus
    case mistral
    case deepseek
    case codebuff
    case crof
    case venice
    case commandcode
    case qoder
    case stepfun
    case bedrock
    case grok
    case groq
    case llmproxy
    case litellm
    case deepgram
    case poe
    case chutes
    case crossmodel

    /// Unknown raw values (a newer macOS build adding a provider) decode without crashing.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = UsageProvider(rawValue: raw) ?? .unknownFallback
    }

    /// Sentinel used when decoding an unrecognized provider from a newer sender.
    public static let unknownFallback: UsageProvider = .codex
}

public extension UsageProvider {
    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .openai: "OpenAI"
        case .azureopenai: "Azure OpenAI"
        case .claude: "Claude"
        case .cursor: "Cursor"
        case .opencode: "OpenCode"
        case .opencodego: "OpenCode Go"
        case .alibaba: "Alibaba"
        case .alibabatokenplan: "Alibaba Token Plan"
        case .factory: "Factory"
        case .gemini: "Gemini"
        case .antigravity: "Antigravity"
        case .copilot: "GitHub Copilot"
        case .devin: "Devin"
        case .zai: "z.ai"
        case .minimax: "MiniMax"
        case .manus: "Manus"
        case .kimi: "Kimi"
        case .kilo: "Kilo"
        case .kiro: "Kiro"
        case .vertexai: "Vertex AI"
        case .augment: "Augment"
        case .jetbrains: "JetBrains AI"
        case .kimik2: "Kimi K2"
        case .moonshot: "Moonshot"
        case .amp: "Amp"
        case .t3chat: "T3 Chat"
        case .ollama: "Ollama"
        case .synthetic: "Synthetic"
        case .warp: "Warp"
        case .openrouter: "OpenRouter"
        case .elevenlabs: "ElevenLabs"
        case .windsurf: "Windsurf"
        case .zed: "Zed"
        case .perplexity: "Perplexity"
        case .mimo: "MiMo"
        case .doubao: "Doubao"
        case .sakana: "Sakana"
        case .abacus: "Abacus"
        case .mistral: "Mistral"
        case .deepseek: "DeepSeek"
        case .codebuff: "Codebuff"
        case .crof: "CROF"
        case .venice: "Venice"
        case .commandcode: "Command Code"
        case .qoder: "Qoder"
        case .stepfun: "StepFun"
        case .bedrock: "Bedrock"
        case .grok: "Grok"
        case .groq: "Groq"
        case .llmproxy: "LLM Proxy"
        case .litellm: "LiteLLM"
        case .deepgram: "Deepgram"
        case .poe: "Poe"
        case .chutes: "Chutes"
        case .crossmodel: "CrossModel"
        }
    }

    /// Name of the bundled vector icon asset (`ProviderIcon-<slug>` in the asset catalog).
    /// Returns `nil` when no dedicated icon exists; callers fall back to an SF Symbol.
    var iconAssetName: String? {
        let slug: String? = switch self {
        case .openai, .azureopenai: "codex"
        case .alibabatokenplan: "alibaba"
        case .kimik2, .moonshot: "kimi"
        default: Self.iconSlugs.contains(self.rawValue) ? self.rawValue : nil
        }
        return slug.map { "ProviderIcon-\($0)" }
    }

    /// Brand accent, used for bars, glass tints, and rings. Neutral default keeps unknowns legible.
    var accentHex: String {
        switch self {
        case .codex, .openai, .azureopenai: "10A37F"
        case .claude: "D97757"
        case .cursor: "000000"
        case .gemini, .vertexai, .antigravity: "4285F4"
        case .copilot: "6E40C9"
        case .grok: "1DA1F2"
        case .mistral: "FF7000"
        case .deepseek: "4D6BFE"
        case .perplexity: "20808D"
        case .kimi, .kimik2, .moonshot: "6B4EFF"
        case .zai: "2F6BFF"
        case .minimax: "FF4D4F"
        case .factory: "E8552D"
        case .warp: "01A4FF"
        case .zed: "084CCF"
        case .elevenlabs: "111111"
        case .groq: "F55036"
        case .windsurf: "09B6A2"
        default: "5E5CE6"
        }
    }

    private static let iconSlugs: Set<String> = [
        "abacus", "alibaba", "amp", "antigravity", "augment", "bedrock", "chutes", "claude",
        "codebuff", "codex", "commandcode", "copilot", "crof", "crossmodel", "cursor", "deepgram",
        "deepseek", "devin", "doubao", "elevenlabs", "factory", "gemini", "grok", "groq",
        "jetbrains", "kilo", "kimi", "kiro", "litellm", "llmproxy", "manus", "mimo", "minimax",
        "mistral", "ollama", "opencode", "opencodego", "openrouter", "perplexity", "poe", "qoder",
        "sakana", "stepfun", "synthetic", "t3chat", "venice", "vertexai", "warp", "windsurf",
        "zai", "zed",
    ]
}
