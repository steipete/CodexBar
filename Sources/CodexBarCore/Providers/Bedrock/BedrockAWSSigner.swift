import CryptoKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Lightweight AWS Signature Version 4 request signer for Bedrock-related AWS API calls.
enum BedrockAWSSigner {
    struct Credentials: Sendable {
        let accessKeyID: String
        let secretAccessKey: String
        let sessionToken: String?
    }

    /// Signs a `URLRequest` using AWS Signature Version 4.
    static func sign(
        request: inout URLRequest,
        credentials: Credentials,
        region: String,
        service: String,
        date: Date = Date())
    {
        let dateFormatter = Self.dateFormatter()
        let dateStamp = Self.dateStamp(date: date)
        let amzDate = dateFormatter.string(from: date)

        request.setValue(amzDate, forHTTPHeaderField: "X-Amz-Date")
        if let sessionToken = credentials.sessionToken {
            request.setValue(sessionToken, forHTTPHeaderField: "X-Amz-Security-Token")
        }

        let host = request.url?.host ?? ""
        request.setValue(host, forHTTPHeaderField: "Host")

        let bodyHash = Self.sha256Hex(request.httpBody ?? Data())
        request.setValue(bodyHash, forHTTPHeaderField: "x-amz-content-sha256")

        let signedHeaders = Self.signedHeaders(request: request)
        let canonicalRequest = Self.canonicalRequest(
            request: request,
            signedHeaders: signedHeaders,
            bodyHash: bodyHash)

        let credentialScope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            credentialScope,
            Self.sha256Hex(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")

        let signature = Self.calculateSignature(
            secretKey: credentials.secretAccessKey,
            dateStamp: dateStamp,
            region: region,
            service: service,
            stringToSign: stringToSign)

        let authorization = "AWS4-HMAC-SHA256 "
            + "Credential=\(credentials.accessKeyID)/\(credentialScope), "
            + "SignedHeaders=\(signedHeaders.keys), "
            + "Signature=\(signature)"

        request.setValue(authorization, forHTTPHeaderField: "Authorization")
    }

    // MARK: - Private helpers

    private struct SignedHeadersInfo {
        let keys: String
        let canonical: String
    }

    private static func signedHeaders(request: URLRequest) -> SignedHeadersInfo {
        var headers: [(String, String)] = []
        if let allHeaders = request.allHTTPHeaderFields {
            for (key, value) in allHeaders {
                headers.append((key.lowercased(), value.trimmingCharacters(in: .whitespaces)))
            }
        }
        headers.sort { $0.0 < $1.0 }

        let keys = headers.map(\.0).joined(separator: ";")
        let canonical = headers.map { "\($0.0):\($0.1)" }.joined(separator: "\n")
        return SignedHeadersInfo(keys: keys, canonical: canonical)
    }

    private static func canonicalRequest(
        request: URLRequest,
        signedHeaders: SignedHeadersInfo,
        bodyHash: String) -> String
    {
        let method = request.httpMethod ?? "GET"
        let url = request.url!
        let path = url.path.isEmpty ? "/" : url.path
        let query = Self.canonicalQueryString(url: url)

        return [
            method,
            Self.uriEncodePath(path),
            query,
            signedHeaders.canonical + "\n",
            signedHeaders.keys,
            bodyHash,
        ].joined(separator: "\n")
    }

    private static func canonicalQueryString(url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems, !queryItems.isEmpty
        else {
            return ""
        }

        return queryItems
            .map { item in
                let key = Self.uriEncode(item.name)
                let value = Self.uriEncode(item.value ?? "")
                return "\(key)=\(value)"
            }
            .sorted()
            .joined(separator: "&")
    }

    private static func calculateSignature(
        secretKey: String,
        dateStamp: String,
        region: String,
        service: String,
        stringToSign: String) -> String
    {
        let kDate = Self.hmacSHA256(key: Data("AWS4\(secretKey)".utf8), data: Data(dateStamp.utf8))
        let kRegion = Self.hmacSHA256(key: kDate, data: Data(region.utf8))
        let kService = Self.hmacSHA256(key: kRegion, data: Data(service.utf8))
        let kSigning = Self.hmacSHA256(key: kService, data: Data("aws4_request".utf8))
        let signature = Self.hmacSHA256(key: kSigning, data: Data(stringToSign.utf8))
        return signature.map { String(format: "%02x", $0) }.joined()
    }

    private static func hmacSHA256(key: Data, data: Data) -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: symmetricKey)
        return Data(mac)
    }

    private static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func dateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }

    private static func dateStamp(date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    private static func uriEncode(_ string: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }

    private static func uriEncodePath(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false)
            .map { Self.uriEncode(String($0)) }
            .joined(separator: "/")
    }
}
