import CodexBarCore
import Foundation

struct OllamaUIErrorMapper {
    static func userFacingMessage(
        _ raw: String?,
        localize: (String) -> String = L) -> String?
    {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed == OllamaUsageError.safariCookieAccessDenied.localizedDescription {
            return localize("ollama_safari_cookie_access_hint")
        }
        if let browserName = self.browserName(
            in: trimmed,
            suffix: " cookie decryption was declined in Keychain; retry with a manual refresh.")
        {
            return String(format: localize("ollama_browser_cookie_decryption_denied"), browserName)
        }
        if let browserName = self.browserName(
            in: trimmed,
            suffix: " cookie decryption is disabled in CodexBar; enable Keychain access and refresh.")
        {
            return String(format: localize("ollama_browser_cookie_decryption_disabled"), browserName)
        }
        return trimmed
    }

    private static func browserName(in message: String, suffix: String) -> String? {
        guard message.hasSuffix(suffix) else { return nil }
        let name = String(message.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}
