import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - OAuth Form Encoding

public enum AntigravityOAuthFormEncoding {
    private static let allowedCharacters: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return allowed
    }()

    public static func bodyData(_ items: [URLQueryItem]) -> Data {
        let encoded = items.map { item in
            let name = self.percentEncode(item.name)
            let value = self.percentEncode(item.value ?? "")
            return "\(name)=\(value)"
        }.joined(separator: "&")

        return Data(encoded.utf8)
    }

    private static func percentEncode(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: self.allowedCharacters) ?? string
    }
}
