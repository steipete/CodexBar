import Foundation

public struct HTTPParsedRequest: Sendable {
    public let method: String
    public let path: String
    public let host: String
    public let headers: [(String, String)]
    public let body: Data?

    public init(method: String, path: String, host: String, headers: [(String, String)], body: Data?) {
        self.method = method
        self.path = path
        self.host = host
        self.headers = headers
        self.body = body
    }
}

public enum HTTPRequestParser {
    public static func parse(data: Data) -> HTTPParsedRequest? {
        guard let string = String(data: data, encoding: .utf8) else { return nil }

        let parts = string.components(separatedBy: "\r\n\r\n")
        guard let headerSection = parts.first else { return nil }

        let lines = headerSection.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }

        let requestParts = requestLine.split(separator: " ", maxSplits: 2)
        guard requestParts.count >= 2 else { return nil }

        let method = String(requestParts[0])
        let path = String(requestParts[1])

        var headers: [(String, String)] = []
        var host = ""

        for line in lines.dropFirst() {
            if let colonIndex = line.firstIndex(of: ":") {
                let key = String(line[line.startIndex..<colonIndex]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                headers.append((key, value))
                if key.lowercased() == "host" {
                    host = value
                }
            }
        }

        let body: Data?
        if parts.count > 1 {
            let bodyString = parts.dropFirst().joined(separator: "\r\n\r\n")
            body = bodyString.data(using: .utf8)
        } else {
            body = nil
        }

        return HTTPParsedRequest(
            method: method,
            path: path,
            host: host,
            headers: headers,
            body: body)
    }
}
