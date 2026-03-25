import CodexBarCore
import Foundation

enum LinuxDashboardPayloadCodec {
    static func decodePayloads(_ rawJSON: String) throws -> [LinuxProviderPayload] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = rawJSON.data(using: .utf8) else {
            throw LinuxDashboardPayloadCodecError.decodeFailed("No se pudo leer la salida JSON.")
        }
        do {
            return try decoder.decode([LinuxProviderPayload].self, from: data)
        } catch {
            throw LinuxDashboardPayloadCodecError.decodeFailed(
                "No se pudo decodificar JSON del CLI: \(error.localizedDescription)")
        }
    }

    static func errorPayload(from error: SubprocessRunnerError) -> String {
        let message = error.localizedDescription
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return """
        [
          {
            "provider": "cli",
            "account": null,
            "version": null,
            "source": "cli",
            "status": null,
            "usage": null,
            "credits": null,
            "antigravityPlanInfo": null,
            "openaiDashboard": null,
            "error": {
              "code": 1,
              "message": "\(message)",
              "kind": "runtime"
            }
          }
        ]
        """
    }
}

enum LinuxDashboardPayloadCodecError: LocalizedError {
    case decodeFailed(String)

    var errorDescription: String? {
        switch self {
        case let .decodeFailed(message):
            return message
        }
    }
}
