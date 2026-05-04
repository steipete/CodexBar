import Foundation
import Network

public final class LocalProxyServer: @unchecked Sendable {
    private static let log = CodexBarLog.logger("proxy-server")

    private let configuration: ProxyConfiguration
    private let accumulator: TokenAccumulator
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.codexbar.proxy", qos: .utility)
    private var isRunning = false

    public init(configuration: ProxyConfiguration, accumulator: TokenAccumulator) {
        self.configuration = configuration
        self.accumulator = accumulator
    }

    public func start() throws {
        guard !self.isRunning else { return }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: self.configuration.port)!)
        self.listener = listener

        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                Self.log.info("Proxy server ready on \(self?.configuration.bindAddress ?? ""):\(self?.configuration.port ?? 0)")
                self?.isRunning = true
            case .failed(let error):
                Self.log.error("Proxy server failed: \(error)")
                self?.isRunning = false
            case .cancelled:
                self?.isRunning = false
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener.start(queue: self.queue)
    }

    public func stop() {
        self.listener?.cancel()
        self.listener = nil
        self.isRunning = false
        Self.log.info("Proxy server stopped")
    }

    public var running: Bool { self.isRunning }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: self.queue)

        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, let data, !data.isEmpty else {
                if let error { Self.log.error("Receive error: \(error)") }
                connection.cancel()
                return
            }

            self.processRequest(data: data, connection: connection)

            if isComplete {
                connection.cancel()
            }
        }
    }

    private func processRequest(data: Data, connection: NWConnection) {
        guard let request = HTTPRequestParser.parse(data: data) else {
            let errorResponse = HTTPResponseWriter.proxyError(statusCode: 400, message: "Bad Request")
            self.send(errorResponse, on: connection)
            return
        }

        let targetHost = request.host.components(separatedBy: ":").first ?? request.host
        let provider = self.identifyProvider(host: targetHost)

        var targetURL = "https://\(request.host)\(request.path)"
        if !targetURL.hasPrefix("https://") {
            targetURL = "https://\(request.host)\(request.path)"
        }

        guard let url = URL(string: targetURL) else {
            let errorResponse = HTTPResponseWriter.proxyError(statusCode: 400, message: "Invalid URL")
            self.send(errorResponse, on: connection)
            return
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body

        for (key, value) in request.headers where key.lowercased() != "host" {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        let isSSE = request.path.contains("/chat/completions") ||
            request.headers.contains(where: { $0.0.lowercased() == "accept" && $0.1.contains("text/event-stream") })

        let task = URLSession.shared.dataTask(with: urlRequest) { [weak self] responseData, response, error in
            guard let self else { return }

            if let error {
                Self.log.error("Forward error: \(error)")
                let errorResponse = HTTPResponseWriter.proxyError(statusCode: 502, message: "Bad Gateway")
                self.send(errorResponse, on: connection)
                return
            }

            guard let httpResponse = response as? HTTPURLResponse,
                  let responseData else {
                let errorResponse = HTTPResponseWriter.proxyError(statusCode: 502, message: "No response")
                self.send(errorResponse, on: connection)
                return
            }

            self.extractUsage(from: responseData, provider: provider, isSSE: isSSE)

            var responseHeaders: [(String, String)] = []
            for (key, value) in httpResponse.allHeaderFields {
                if let keyStr = key as? String, let valueStr = value as? String {
                    if keyStr.lowercased() != "transfer-encoding" {
                        responseHeaders.append((keyStr, valueStr))
                    }
                }
            }

            let proxyResponse = HTTPResponseWriter.write(
                statusCode: httpResponse.statusCode,
                headers: responseHeaders,
                body: responseData)
            self.send(proxyResponse, on: connection)
        }

        task.resume()
    }

    private func extractUsage(from data: Data, provider: UsageProvider?, isSSE: Bool) {
        guard let provider else { return }

        if isSSE {
            self.extractUsageFromSSE(data: data, provider: provider)
        } else {
            self.extractUsageFromJSON(data: data, provider: provider)
        }
    }

    private func extractUsageFromJSON(data: Data, provider: UsageProvider) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = json["usage"] as? [String: Any]
        else { return }

        self.recordUsage(usage: usage, provider: provider)
    }

    private func extractUsageFromSSE(data: Data, provider: UsageProvider) {
        guard let text = String(data: data, encoding: .utf8) else { return }

        let lines = text.components(separatedBy: "\n")
        for line in lines {
            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst("data: ".count))
            guard jsonString != "[DONE]",
                  let jsonData = jsonString.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let usage = json["usage"] as? [String: Any]
            else { continue }

            self.recordUsage(usage: usage, provider: provider)
        }
    }

    private func recordUsage(usage: [String: Any], provider: UsageProvider) {
        let promptTokens = usage["prompt_tokens"] as? Int ?? 0
        let completionTokens = usage["completion_tokens"] as? Int ?? 0
        let totalTokens = usage["total_tokens"] as? Int ?? (promptTokens + completionTokens)
        let model = usage["model"] as? String

        guard promptTokens > 0 || completionTokens > 0 else { return }

        self.accumulator.record(
            provider: provider,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            totalTokens: totalTokens,
            model: model)

        Self.log.info("Recorded \(provider): prompt=\(promptTokens) completion=\(completionTokens) total=\(totalTokens)")
    }

    private func send(_ data: Data, on connection: NWConnection) {
        connection.send(content: data, completion: .contentProcessed { error in
            if let error {
                Self.log.error("Send error: \(error)")
            }
            connection.cancel()
        })
    }

    private func identifyProvider(host: String) -> UsageProvider? {
        switch host {
        case "api.deepseek.com": return .deepseek
        case "open.bigmodel.cn": return .zhipu
        case "ark.cn-beijing.volces.com": return .doubao
        case "qianfan.baidubce.com": return .ernie
        case "api.moonshot.cn": return .kimi
        case "api.minimax.chat": return .minimax
        case "api.xiaomimimo.com": return .mimo
        default: return nil
        }
    }
}
