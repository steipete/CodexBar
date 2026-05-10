import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension GeminiStatusProbe {
    public static func defaultDataLoader(for request: URLRequest) async throws -> (Data, URLResponse) {
        let loader = Self.dataLoaderWithCurlFallback(
            primary: { request in
                try await URLSession.shared.data(for: request)
            },
            fallback: Self.curlDataLoader)
        return try await loader(request)
    }

    public static func dataLoaderWithCurlFallback(
        primary: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse),
        fallback: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse))
        -> @Sendable (URLRequest) async throws -> (Data, URLResponse)
    {
        { request in
            do {
                return try await primary(request)
            } catch {
                guard Self.isURLSessionTimeout(error) else {
                    throw error
                }
                CodexBarLog.logger(LogCategories.geminiProbe)
                    .warning("Gemini URLSession timed out; retrying with curl")
                return try await fallback(request)
            }
        }
    }

    private static func isURLSessionTimeout(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return urlError.code == .timedOut
        }

        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut
    }

    private static func curlDataLoader(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url else {
            throw URLError(.badURL)
        }

        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory
            .appendingPathComponent("codexbar-gemini-curl-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer {
            try? fileManager.removeItem(at: tempDir)
        }

        let configURL = tempDir.appendingPathComponent("curl.conf")
        var config = [
            "silent",
            "show-error",
            "location",
            "url = \(Self.curlConfigQuote(url.absoluteString))",
            "max-time = \(max(1, Int(ceil(request.timeoutInterval))))",
        ]

        if let method = request.httpMethod, !method.isEmpty {
            config.append("request = \(Self.curlConfigQuote(method))")
        }

        for (name, value) in (request.allHTTPHeaderFields ?? [:]).sorted(by: { $0.key < $1.key }) {
            let header = "\(name): \(value)"
            guard !header.contains("\n"), !header.contains("\r") else {
                throw GeminiStatusProbeError.apiError("Invalid request header")
            }
            config.append("header = \(Self.curlConfigQuote(header))")
        }

        if let body = request.httpBody {
            let bodyURL = tempDir.appendingPathComponent("body")
            try body.write(to: bodyURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bodyURL.path)
            config.append("data-binary = \(Self.curlConfigQuote("@\(bodyURL.path)"))")
        }

        config.append("write-out = \(Self.curlConfigQuote(Self.curlHTTPStatusMarker + "%{http_code}"))")
        try config.joined(separator: "\n").write(to: configURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)

        let result = try await SubprocessRunner.run(
            binary: "/usr/bin/curl",
            arguments: ["--config", configURL.path],
            environment: TTYCommandRunner.enrichedEnvironment(),
            timeout: max(5, request.timeoutInterval + 2),
            label: "gemini-api-curl")

        return try Self.parseCurlDataLoaderResult(result.stdout, url: url)
    }

    private static let curlHTTPStatusMarker = "__CODEXBAR_HTTP_STATUS__:"

    private static func curlConfigQuote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func parseCurlDataLoaderResult(_ output: String, url: URL) throws -> (Data, URLResponse) {
        guard let markerRange = output.range(of: curlHTTPStatusMarker, options: .backwards) else {
            throw GeminiStatusProbeError.apiError("curl response missing HTTP status")
        }

        let body = String(output[..<markerRange.lowerBound])
        let statusText = output[markerRange.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let statusCode = Int(statusText), statusCode > 0,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: statusCode,
                  httpVersion: nil,
                  headerFields: nil)
        else {
            throw GeminiStatusProbeError.apiError("curl response had invalid HTTP status")
        }

        return (Data(body.utf8), response)
    }
}
