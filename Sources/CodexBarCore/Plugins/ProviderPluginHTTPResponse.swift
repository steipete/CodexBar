import CoreFoundation
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Shared request policy and HTTP values exposed to both plugin engines.
enum ProviderPluginHTTPResponse {
    struct Payload: @unchecked Sendable {
        let value: [String: Any]
    }

    struct Request: Sendable {
        let primary: URLRequest
        let optional: URLRequest?
        let retryPolicy: ProviderHTTPRetryPolicy
        let optionalBudget: Duration?
        let cookieJar: ProviderPluginCookieJar?
        let primarySession: String?
        let optionalSession: String?
        let hidesResponseCookies: Bool

        init(
            rawURL: String,
            options: [String: Any],
            method: String,
            settings: [String: String],
            secrets: [String: String],
            manifest: ProviderPluginManifest,
            enforcesUserResponsePolicy: Bool,
            redactionValues: ProviderPluginRedactionValues? = nil,
            cookieJar: ProviderPluginCookieJar? = nil) throws
        {
            self.cookieJar = cookieJar
            self.hidesResponseCookies = manifest.cookiePolicy?.selectedProfile == true
            self.primarySession = options["cookieSession"] as? String
            let optionalOptions = (options["optionalRequest"] as? [String: Any])?["options"] as? [String: Any]
            self.optionalSession = optionalOptions?["cookieSession"] as? String
            Self.redactForm(options, into: redactionValues)
            if let budget = options["optionalBudgetSeconds"] {
                guard let number = budget as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue.isFinite, (0...5).contains(number.doubleValue)
                else { throw ProviderPluginError.http("optionalBudgetSeconds must be a number from 0 through 5") }
                self.optionalBudget = .seconds(number.doubleValue)
            } else {
                self.optionalBudget = nil
            }
            self.retryPolicy = try ProviderPluginHTTPResponse.retryPolicy(
                options["retryPolicy"].map(JSONProviderPluginValue.init))
            self.primary = try ProviderPluginHTTPResponse.request(
                rawURL: rawURL,
                options: options,
                method: method,
                settings: settings,
                secrets: secrets,
                manifest: manifest,
                enforcesUserResponsePolicy: enforcesUserResponsePolicy,
                cookieJar: cookieJar)
            if let optional = options["optionalRequest"] {
                guard method == "GET", let value = optional as? [String: Any],
                      let url = value["url"] as? String, let optionalMethod = value["method"] as? String,
                      optionalMethod == "GET" || optionalMethod == "POST",
                      let optionalOptions = value["options"] as? [String: Any]
                else {
                    throw ProviderPluginError.http("optional request requires a GET primary and GET or POST options")
                }
                Self.redactForm(optionalOptions, into: redactionValues)
                var request = try ProviderPluginHTTPResponse.request(
                    rawURL: url,
                    options: optionalOptions,
                    method: optionalMethod,
                    settings: settings,
                    secrets: secrets,
                    manifest: manifest,
                    enforcesUserResponsePolicy: enforcesUserResponsePolicy,
                    cookieJar: cookieJar)
                request.timeoutInterval = min(request.timeoutInterval, 5)
                self.optional = request
            } else {
                self.optional = nil
            }
        }

        func transport(_ base: any ProviderHTTPTransport, session: String?) -> any ProviderHTTPTransport {
            guard let cookieJar, let session else { return base }
            return ProviderPluginCookieTransport(base: base, jar: cookieJar, id: session)
        }

        private static func redactForm(_ options: [String: Any], into redactionValues: ProviderPluginRedactionValues?) {
            if let form = options["form"] as? [String: String] {
                for value in form.values {
                    redactionValues?.insert(value)
                    redactionValues?.insert(FormURLEncoding.encode(value))
                    if let json = try? JSONSerialization.data(
                        withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]),
                        let escaped = String(data: json, encoding: .utf8)
                    {
                        redactionValues?.insert(String(escaped.dropFirst().dropLast()))
                    }
                }
            }
        }
    }

    enum Completion: Sendable {
        case primary(ProviderHTTPResponse)
        case optional(ProviderHTTPResponse?)
        case budgetExpired
    }

    // swiftlint:disable:next function_parameter_count
    static func fetch(
        _ request: Request,
        transport: any ProviderHTTPTransport,
        wantsJSON: Bool,
        responseSizeLimit: Int,
        enforcesUserResponsePolicy: Bool,
        rejectsNonSuccessResponses: Bool,
        contextOptions: ProviderPluginContextOptions = .production) async throws -> Payload
    {
        let collectionBudget = request.optionalBudget ?? contextOptions.optionalCollectionBudget
        let (starts, started) = AsyncStream<ContinuousClock.Instant>.makeStream(bufferingPolicy: .bufferingNewest(1))
        return try await withThrowingTaskGroup(of: Completion.self) { group in
            defer { group.cancelAll() }
            group.addTask {
                defer { started.finish() }
                return try await .primary(self.response(
                    for: request.primary,
                    transport: request.transport(transport, session: request.primarySession),
                    retryPolicy: request.retryPolicy,
                    beforeAttempt: { request in
                        try await contextOptions.beforeHTTPAttempt?(request)
                        started.yield(.now)
                        started.finish()
                    }))
            }
            if let optional = request.optional {
                group.addTask {
                    await .optional(try? self.response(
                        for: optional,
                        transport: request.transport(transport, session: request.optionalSession),
                        retryPolicy: .disabled,
                        beforeAttempt: contextOptions.beforeHTTPAttempt))
                }
                group.addTask {
                    // Admission and scheduling waits belong to the overall fetch timeout.
                    var iterator = starts.makeAsyncIterator()
                    if let start = await iterator.next() {
                        try await contextOptions.waitForOptionalDeadline(start, collectionBudget)
                    }
                    return .budgetExpired
                }
            }
            var primary: ProviderHTTPResponse?
            var optional: ProviderHTTPResponse?
            var optionalFinished = request.optional == nil
            var budgetExpired = false
            while let completion = try await group.next() {
                switch completion {
                case let .primary(response): primary = response
                case let .optional(response):
                    optional = response
                    optionalFinished = true
                case .budgetExpired: budgetExpired = true
                }
                contextOptions.didCollectHTTPCompletion?(completion)
                // After expiry, retain optional results only while the required request is still pending.
                if let primary, optionalFinished || budgetExpired || !(200..<300).contains(primary.statusCode) {
                    break
                }
            }
            try Task.checkCancellation()
            guard let primary else { throw CancellationError() }
            var payload = try self.checkedPayload(
                primary,
                wantsJSON: wantsJSON,
                responseSizeLimit: responseSizeLimit,
                enforcesUserResponsePolicy: enforcesUserResponsePolicy,
                rejectsNonSuccessResponses: rejectsNonSuccessResponses,
                allowsRetry: request.retryPolicy.maxRetries == 0,
                hidesResponseCookies: request.hidesResponseCookies)
            if request.optional != nil {
                if let optional, (200..<300).contains(primary.statusCode) {
                    payload["optional"] = try? self.checkedPayload(
                        optional,
                        wantsJSON: wantsJSON,
                        responseSizeLimit: responseSizeLimit,
                        enforcesUserResponsePolicy: enforcesUserResponsePolicy,
                        rejectsNonSuccessResponses: true,
                        allowsRetry: false,
                        hidesResponseCookies: request.hidesResponseCookies)
                }
                if payload["optional"] == nil { payload["optional"] = NSNull() }
            }
            return Payload(value: payload)
        }
    }

    // swiftlint:disable:next function_parameter_count
    private static func checkedPayload(
        _ response: ProviderHTTPResponse,
        wantsJSON: Bool,
        responseSizeLimit: Int,
        enforcesUserResponsePolicy: Bool,
        rejectsNonSuccessResponses: Bool,
        allowsRetry: Bool,
        hidesResponseCookies: Bool) throws -> [String: Any]
    {
        guard response.data.count <= responseSizeLimit else {
            throw ProviderPluginError.http("response exceeded the \(responseSizeLimit)-byte limit")
        }
        if rejectsNonSuccessResponses, !(200..<300).contains(response.statusCode) {
            throw StatusFailure(response: response.response, allowsRetry: allowsRetry)
        }
        if enforcesUserResponsePolicy,
           let encoding = response.response.value(forHTTPHeaderField: "Content-Encoding"),
           !encoding.isEmpty, encoding.caseInsensitiveCompare("identity") != .orderedSame
        {
            throw ProviderPluginError.http("compressed responses are not allowed")
        }
        return try self.payload(response, wantsJSON: wantsJSON, hidesResponseCookies: hidesResponseCookies)
    }

    // swiftlint:disable:next function_parameter_count
    static func request(
        rawURL: String,
        options: [String: Any],
        method: String,
        settings: [String: String],
        secrets: [String: String],
        manifest: ProviderPluginManifest,
        enforcesUserResponsePolicy: Bool,
        cookieJar: ProviderPluginCookieJar? = nil) throws -> URLRequest
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
        if method == "POST" { request.httpBody = try Self.postBody(options) }
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
            request.setValue(
                options["form"] == nil ? "application/json" : "application/x-www-form-urlencoded",
                forHTTPHeaderField: "Content-Type")
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
        try ProviderPluginCookieJar.authenticate(
            &request, sessionID: options["cookieSession"], required: manifest.usesCookieJar, jar: cookieJar)
        return request
    }

    private static func postBody(_ options: [String: Any]) throws -> Data {
        if let form = options["form"] {
            guard let fields = form as? [String: String], options["bodyJSON"] == nil, options["body"] == nil else {
                throw ProviderPluginError.http("POST form requires a string-to-string map and no JSON body")
            }
            return FormURLEncoding.body(fields)
        }
        guard let bodyJSON = options["bodyJSON"] as? String else {
            throw ProviderPluginError.http("POST JSON body is missing")
        }
        return Data(bodyJSON.utf8)
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
        beforeAttempt: (@Sendable (URLRequest) async throws -> Void)? = nil) async throws -> ProviderHTTPResponse
    {
        let bounded = ProviderHTTPTransportHandler { request in
            try Task.checkCancellation()
            let (starts, started) = AsyncStream<ContinuousClock.Instant>.makeStream()
            let task = Task {
                defer { started.finish() }
                try await beforeAttempt?(request)
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
        _ error: Error,
        message: String,
        transportErrors: TransportErrors? = nil) -> [String: Any]
    {
        var payload: [String: Any] = ["message": message]
        if let classified = error as? ProviderFetchClassifiedError {
            payload["failureKind"] = classified.kind.rawValue
        }
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

    static func payload(_ response: ProviderHTTPResponse, wantsJSON: Bool, hidesResponseCookies: Bool = false)
        throws -> [String: Any]
    {
        var headers: [String: String] = [:]
        for (key, value) in response.response.allHeaderFields {
            let name = String(describing: key).lowercased()
            if hidesResponseCookies, ["cookie", "set-cookie", "set-cookie2"].contains(name) { continue }
            headers[name] = String(describing: value)
        }
        var payload: [String: Any] = [
            "status": response.statusCode,
            "url": response.response.url?.absoluteString ?? "",
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
