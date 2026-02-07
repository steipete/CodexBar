import Foundation

public struct CLIProxyAPIManagementClient: Sendable {
    private let baseURL: URL
    private let managementKey: String

    public init(baseURL: URL, managementKey: String) {
        self.baseURL = baseURL
        self.managementKey = managementKey
    }

    public func listAuthFiles() async throws -> [CLIProxyAPIAuthFile] {
        let response: CLIProxyAPIAuthFilesResponse = try await self.sendRequest(
            path: "auth-files",
            method: "GET",
            body: nil)
        return response.files
    }

    public func downloadAuthFile(name: String) async throws -> Data {
        var components = URLComponents(url: self.baseURL.appendingPathComponent("auth-files/download"),
                                       resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "name", value: name)]
        guard let url = components?.url else {
            throw CLIProxyAPIClientError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(self.managementKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        try self.validateHTTP(response: response, data: data)
        return data
    }

    func apiCall(_ payload: CLIProxyAPIApiCallRequest) async throws -> CLIProxyAPIApiCallResponse {
        let data = try JSONEncoder().encode(payload)
        return try await self.sendRequest(path: "api-call", method: "POST", body: data)
    }

    private func sendRequest<T: Decodable>(path: String, method: String, body: Data?) async throws -> T {
        var url = self.baseURL
        url.appendPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(self.managementKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        try self.validateHTTP(response: response, data: data)
        let decoder = JSONDecoder()
        return try decoder.decode(T.self, from: data)
    }

    private func validateHTTP(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw CLIProxyAPIClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8)
            throw CLIProxyAPIClientError.httpError(http.statusCode, message)
        }
    }
}

enum CLIProxyAPIClientError: LocalizedError, Sendable {
    case invalidURL
    case invalidResponse
    case httpError(Int, String?)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "CLIProxyAPI management URL is invalid."
        case .invalidResponse:
            return "CLIProxyAPI management response is invalid."
        case let .httpError(code, message):
            if let message, !message.isEmpty {
                return "CLIProxyAPI management error \(code): \(message)"
            }
            return "CLIProxyAPI management error \(code)."
        }
    }
}
