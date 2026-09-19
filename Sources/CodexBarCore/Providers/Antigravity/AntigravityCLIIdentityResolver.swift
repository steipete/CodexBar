import Foundation
import Security

enum AntigravityCLIIdentityResolver {
    /// Attempts to find the email address associated with the local `agy` CLI login.
    static func resolveCLIEmail(env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let email = resolveFromKeychain() {
            return email
        }
        if let email = resolveFromConfig(env: env) {
            return email
        }
        return nil
    }

    private static func resolveFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "gemini",
            kSecAttrAccount as String: "antigravity",
            kSecReturnAttributes as String: true,
            kSecReturnData as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let dict = item as? [String: Any] else {
            return nil
        }

        let possibleFields = [kSecAttrDescription, kSecAttrComment, kSecAttrGeneric, kSecAttrLabel]
        for field in possibleFields {
            if let data = dict[field as String] as? Data,
               let str = String(data: data, encoding: .utf8),
               let email = extractEmail(from: str)
            {
                return email
            }
            if let str = dict[field as String] as? String,
               let email = extractEmail(from: str)
            {
                return email
            }
        }
        return nil
    }

    private static func resolveFromConfig(env: [String: String]) -> String? {
        let home = env["HOME"] ?? NSHomeDirectory()
        let configDir = URL(fileURLWithPath: home).appendingPathComponent(".gemini/antigravity-cli")
        let candidates = ["settings.json", "auth.json", "jetski_state.pbtxt"]

        for candidate in candidates {
            let fileURL = configDir.appendingPathComponent(candidate)
            if let content = try? String(contentsOf: fileURL, encoding: .utf8),
               let email = extractEmail(from: content)
            {
                return email
            }
        }
        return nil
    }

    private static func extractEmail(from text: String) -> String? {
        let pattern = "[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,64}"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        if let match = regex.firstMatch(in: text, options: [], range: nsRange) {
            if let range = Range(match.range, in: text) {
                return String(text[range])
            }
        }
        return nil
    }
}
