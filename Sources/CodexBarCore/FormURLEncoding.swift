import Foundation

enum FormURLEncoding {
    static func body(_ parameters: [String: String]) -> Data {
        self.body(parameters.map { ($0.key, $0.value) })
    }

    static func body(_ parameters: [(String, String)]) -> Data {
        let pairs = parameters
            .map { key, value in
                "\(Self.encode(key))=\(Self.encode(value))"
            }
            .joined(separator: "&")
        return Data(pairs.utf8)
    }

    private static func encode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
