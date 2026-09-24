import CoreFoundation
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Shared request policy and HTTP values exposed to both plugin engines.
enum ProviderPluginHTTPResponse {
    // swiftlint:disable:next function_parameter_count
    static func request(
        rawURL: String,
        options: [String: Any],
        method: String,
        settings: [String: String],
        secrets: [String: String],
        manifest: ProviderPluginManifest,
        enforcesUserResponsePolicy: Bool) throws -> URLRequest
    {
        guard let url = URL(string: rawURL) else {
            throw ProviderPluginError.networkPolicy("request URL is invalid")
        }
        guard try manifest.allowedOrigin(for: url, settings: settings) else {
            let rejectedOrigin = (try? ProviderPluginOrigin.normalizedOrigin(
                of: url,
                policy: url.scheme?.lowercased() == "http" ? .httpsOrLoopbackHTTP : .https)) ?? "invalid"
            throw ProviderPluginError.networkPolicy("origin '\(rejectedOrigin)' is not declared")
        }
        guard method == "GET" || method == "POST" else {
            throw ProviderPluginError.networkPolicy("HTTP method is not allowed")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = try Self.timeoutSeconds(options)
        if method == "POST" {
            guard let bodyJSON = options["bodyJSON"] as? String else {
                throw ProviderPluginError.http("POST JSON body is missing")
            }
            request.httpBody = Data(bodyJSON.utf8)
        }
        if let headers = options["headers"] as? [String: Any] {
            for (name, rawValue) in headers {
                guard let value = rawValue as? String else {
                    throw ProviderPluginError.http("request header '\(name)' must be a string")
                }
                if let auth = manifest.auth, name.caseInsensitiveCompare(auth.header) == .orderedSame {
                    throw ProviderPluginError.networkPolicy("plugins may not override the auth header")
                }
                request.setValue(value, forHTTPHeaderField: name)
            }
        }
        if enforcesUserResponsePolicy || request.value(forHTTPHeaderField: "Accept") == nil {
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        }
        if enforcesUserResponsePolicy {
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        }
        if method == "POST" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let auth = manifest.auth {
            var secretName = auth.secret
            // Provider-specific by design: first-party OpenRouter Activity uses a separately scoped management key,
            // and the broker pins that exceptional credential to the official read-only endpoint.
            if let managementAuth = options["openRouterManagementAuth"] {
                guard let managementAuth = managementAuth as? NSNumber,
                      CFGetTypeID(managementAuth) == CFBooleanGetTypeID(), managementAuth.boolValue
                else {
                    throw ProviderPluginError.secretAccess(
                        "OpenRouter management auth is unavailable for this plugin")
                }
                secretName = try manifest.openRouterManagementAuthSecret(method: method, url: url)
            }
            guard let credential = secrets[secretName], !credential.isEmpty else {
                throw ProviderPluginError.secretAccess("required auth secret is unavailable")
            }
            let value = switch auth.type {
            case .bearer: "Bearer \(credential)"
            case .authorizationScheme: "\(auth.scheme!) \(credential)"
            case .xAPIKey, .header: credential
            }
            request.setValue(value, forHTTPHeaderField: auth.header)
        }
        return request
    }

    private static func timeoutSeconds(_ options: [String: Any]) throws -> TimeInterval {
        guard let value = options["timeoutSeconds"] else { return 15 }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw ProviderPluginError.http("timeoutSeconds must be a number from 1 through 90")
        }
        let seconds = number.doubleValue
        guard seconds.isFinite, (1...90).contains(seconds) else {
            throw ProviderPluginError.http("timeoutSeconds must be a number from 1 through 90")
        }
        return seconds
    }

    static func response(
        for request: URLRequest,
        transport: any ProviderHTTPTransport,
        retryPolicy: ProviderHTTPRetryPolicy,
        beforeAttempt: (@Sendable () async throws -> Void)? = nil) async throws -> ProviderHTTPResponse
    {
        let bounded = ProviderHTTPTransportHandler { request in
            try Task.checkCancellation()
            let (starts, started) = AsyncStream<ContinuousClock.Instant>.makeStream()
            let task = Task {
                defer { started.finish() }
                try await beforeAttempt?()
                try Task.checkCancellation()
                started.yield(.now)
                return try await transport.data(for: request)
            }
            return try await withTaskCancellationHandler {
                // Scheduling waits consume only the overall fetch budget, not this attempt's timeout.
                var iterator = starts.makeAsyncIterator()
                let startedAt = await iterator.next()
                try Task.checkCancellation()
                guard let startedAt else { return try await task.value }
                let deadline = startedAt.advanced(by: .seconds(request.timeoutInterval))
                let remaining = ContinuousClock.now.duration(to: deadline)
                return switch await BoundedTaskJoin(sourceTask: task).value(joinGrace: remaining) {
                case let .value(response): response
                case let .failure(error): throw error
                case .timedOut: throw URLError(.timedOut)
                }
            } onCancel: {
                task.cancel()
            }
        }
        return try await bounded.response(for: request, retryPolicy: retryPolicy)
    }

    struct StatusFailure: LocalizedError {
        let response: HTTPURLResponse
        let allowsRetry: Bool
        var errorDescription: String? {
            let message = "request returned HTTP \(self.response.statusCode)"
            guard self.allowsRetry else { return message }
            return ProviderPluginTransientHTTPFailure.markerMessage(
                statusCode: self.response.statusCode,
                retryAfterHeader: self.response.value(forHTTPHeaderField: "Retry-After"))
                ?? message
        }
    }

    static func retryPolicy(_ value: (any ProviderPluginValue)?) throws -> ProviderHTTPRetryPolicy {
        guard let value, !value.isUndefined else { return .disabled }
        guard value.isString, value.stringValue() == "transientIdempotent" else {
            throw ProviderPluginError.http("retryPolicy must be 'transientIdempotent'")
        }
        return .transientIdempotent
    }

    static func failure(
        _ error: Error, message: String, transportErrors: TransportErrors? = nil) -> [String: Any]
    {
        var payload: [String: Any] = ["message": message]
        if let failure = error as? StatusFailure {
            payload["status"] = failure.response.statusCode
            payload["transportClass"] = "http"
            payload["retryable"] = ProviderHTTPRetryPolicy.transientIdempotent.retryableStatusCodes
                .contains(failure.response.statusCode)
        }
        let code = error is CancellationError ? URLError.cancelled : (error as? URLError)?.code
        if let code {
            payload["__codexbarTransportError"] = transportErrors?.record(code)
            payload["transportCode"] = code.rawValue
            payload["transportClass"] = switch code {
            case .timedOut: "timeout"
            case .cannotFindHost, .dnsLookupFailed: "dns"
            case .notConnectedToInternet: "offline"
            case .cancelled: "cancelled"
            case .networkConnectionLost, .cannotConnectToHost: "connection"
            case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
                 .clientCertificateRejected, .clientCertificateRequired: "tls"
            default: "other"
            }
            payload["retryable"] = ProviderHTTPRetryPolicy.transientIdempotent.retryableURLErrorCodes.contains(code)
        }
        return payload
    }

    final class TransportErrors: @unchecked Sendable {
        private let lock = NSLock()
        private var codes: [String: URLError.Code] = [:]

        func record(_ code: URLError.Code) -> String {
            let token = UUID().uuidString
            self.lock.withLock { self.codes[token] = code }
            return token
        }

        func error(for value: any ProviderPluginValue) -> Error? {
            guard let token = value.property("__codexbarTransportError"), token.isString,
                  let code = self.lock.withLock({ self.codes[token.stringValue()] })
            else { return nil }
            return code == .cancelled ? CancellationError() : URLError(code)
        }
    }

    static func payload(_ response: ProviderHTTPResponse, wantsJSON: Bool) throws -> [String: Any] {
        var headers: [String: String] = [:]
        for (key, value) in response.response.allHeaderFields {
            headers[String(describing: key).lowercased()] = String(describing: value)
        }
        var payload: [String: Any] = [
            "status": response.statusCode,
            "headers": headers,
        ]
        if wantsJSON {
            do {
                payload["json"] = try JSONSerialization.jsonObject(with: response.data)
            } catch {
                throw ProviderPluginError.http("response was not valid JSON")
            }
        } else {
            guard let text = String(data: response.data, encoding: .utf8) else {
                throw ProviderPluginError.http("response body was not valid UTF-8")
            }
            payload["bodyText"] = text
        }
        return payload
    }
}
