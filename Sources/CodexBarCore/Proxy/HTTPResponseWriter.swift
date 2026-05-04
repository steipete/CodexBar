import Foundation

public enum HTTPResponseWriter {
    public static func write(statusCode: Int, headers: [(String, String)], body: Data) -> Data {
        let statusText = HTTPURLResponse.localizedString(forStatusCode: statusCode)
        var response = "HTTP/1.1 \(statusCode) \(statusText)\r\n"

        var hasContentLength = false
        for (key, value) in headers {
            response += "\(key): \(value)\r\n"
            if key.lowercased() == "content-length" {
                hasContentLength = true
            }
        }

        if !hasContentLength {
            response += "Content-Length: \(body.count)\r\n"
        }

        response += "\r\n"

        var data = Data(response.utf8)
        data.append(body)
        return data
    }

    public static func proxyError(statusCode: Int, message: String) -> Data {
        let body = "{\"error\":\"\(message)\"}"
        return write(
            statusCode: statusCode,
            headers: [("Content-Type", "application/json")],
            body: Data(body.utf8))
    }
}
