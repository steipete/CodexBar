import Foundation

struct CLIServeAuth: Sendable {
    let token: String?

    init(token: String?) {
        self.token = token
    }

    init(dashboardToken: String?) {
        self.init(token: dashboardToken)
    }

    func authorizeDataRequest(_ request: CLILocalHTTPRequest) -> Bool {
        guard let token else { return true }
        guard let authorization = request.headers["authorization"] else { return false }
        return authorization.trimmingCharacters(in: .whitespacesAndNewlines) == "Bearer \(token)"
    }

    func authorizeDashboardRequest(_ request: CLILocalHTTPRequest) -> Bool {
        self.authorizeDataRequest(request)
    }
}

enum CLIServeSecurity {
    static func bindHost(_ host: String) -> String {
        host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "localhost" ? "127.0.0.1" : host
    }

    static func isLoopbackHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "localhost" || normalized == "::1" { return true }
        if normalized.hasPrefix("127.") { return true }
        return normalized == "0:0:0:0:0:0:0:1"
    }

    static func requiresDashboardToken(host: String) -> Bool {
        !self.isLoopbackHost(host)
    }
}
