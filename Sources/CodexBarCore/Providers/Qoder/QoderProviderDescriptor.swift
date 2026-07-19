import Foundation

public enum QoderProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .qoder,
            metadata: ProviderMetadata(
                id: .qoder,
                displayName: "Qoder",
                sessionLabel: "Credits",
                weeklyLabel: "Balance",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "Big model credits from the Qoder usage dashboard.",
                toggleTitle: "Show Qoder usage",
                cliName: "qoder",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: ProviderBrowserCookieDefaults.qoderCookieImportOrder,
                dashboardURL: QoderWebSite.international.dashboardURL.absoluteString,
                statusPageURL: nil,
                statusLinkURL: nil),
            branding: ProviderBranding(
                iconStyle: .qoder,
                iconResourceName: "ProviderIcon-qoder",
                color: ProviderColor(red: 16 / 255, green: 185 / 255, blue: 129 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x2ADB5C),
                    ProviderColor(hex: 0x111113),
                    ProviderColor(hex: 0xFFFFFF),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Qoder cost summary is not supported." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [QoderWebFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "qoder",
                aliases: [],
                versionDetector: nil))
    }

    public static func dashboardURL(
        settings: ProviderSettingsSnapshot.QoderProviderSettings?,
        sourceLabel: String?) -> URL
    {
        guard settings?.cookieSource == .manual else {
            return self.dashboardURL(forSourceLabel: sourceLabel)
        }
        guard let site = QoderWebFetchStrategy.site(forManualCookieHeader: settings?.manualCookieHeader) else {
            return QoderWebSite.international.dashboardURL
        }
        return site.dashboardURL
    }

    public static func dashboardURL(forSourceLabel sourceLabel: String?) -> URL {
        guard let sourceLabel, !sourceLabel.isEmpty else {
            return QoderWebSite.international.dashboardURL
        }
        return QoderWebFetchStrategy.site(for: sourceLabel).dashboardURL
    }
}

struct QoderWebFetchStrategy: ProviderFetchStrategy {
    typealias UsageLoader = @Sendable (String, QoderWebSite, TimeInterval) async throws -> QoderUsageSnapshot
    typealias CookieResolver = @Sendable (ProviderFetchContext, Bool, Set<String>) throws -> QoderResolvedCookie?

    let id: String = "qoder.web"
    let kind: ProviderFetchKind = .web
    private let usageLoader: UsageLoader
    private let cookieResolver: CookieResolver

    init(
        usageLoader: @escaping UsageLoader = { cookieHeader, site, timeout in
            try await QoderUsageFetcher.fetchUsage(
                cookieHeader: cookieHeader,
                site: site,
                timeout: timeout)
        },
        cookieResolver: @escaping CookieResolver = QoderWebFetchStrategy.resolveCookieHeader)
    {
        self.usageLoader = usageLoader
        self.cookieResolver = cookieResolver
    }

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        let cookieSource = context.settings?.qoder?.cookieSource ?? .auto
        guard cookieSource != .off else { return false }
        if cookieSource == .manual {
            return CookieHeaderNormalizer.normalize(context.settings?.qoder?.manualCookieHeader) != nil
        }
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let cookieSource = context.settings?.qoder?.cookieSource ?? .auto
        let shouldRetry = cookieSource != .manual || Self.shouldRetryManualCookieHeader(
            context.settings?.qoder?.manualCookieHeader)
        var skippedSourceLabels = Set<String>()
        var allowCached = true
        var sawInvalidCredentials = false
        var terminalNonAuthError: Error?

        while true {
            let resolvedCookie: QoderResolvedCookie
            do {
                guard let candidate = try self.cookieResolver(
                    context,
                    allowCached,
                    skippedSourceLabels)
                else {
                    if let exhaustionError = Self.errorForExhaustion(
                        terminalNonAuthError: terminalNonAuthError,
                        sawInvalidCredentials: sawInvalidCredentials)
                    {
                        throw exhaustionError
                    }
                    throw QoderUsageError.missingCredentials
                }
                resolvedCookie = candidate
            } catch QoderUsageError.missingCredentials
                where terminalNonAuthError != nil || sawInvalidCredentials
            {
                if let exhaustionError = Self.errorForExhaustion(
                    terminalNonAuthError: terminalNonAuthError,
                    sawInvalidCredentials: sawInvalidCredentials)
                {
                    throw exhaustionError
                }
                throw QoderUsageError.missingCredentials
            }

            do {
                let snapshot = try await self.usageLoader(
                    resolvedCookie.cookieHeader,
                    Self.site(for: resolvedCookie.sourceLabel),
                    context.webTimeout)
                return self.makeResult(
                    usage: snapshot.toUsageSnapshot(),
                    sourceLabel: resolvedCookie.sourceLabel)
            } catch is CancellationError {
                throw CancellationError()
            } catch let fetchError {
                guard shouldRetry else { throw fetchError }
                if case QoderUsageError.invalidCredentials = fetchError {
                    CookieHeaderCache.clear(provider: .qoder)
                    sawInvalidCredentials = true
                } else {
                    terminalNonAuthError = fetchError
                }
                if !resolvedCookie.isFromCache {
                    skippedSourceLabels.insert(resolvedCookie.sourceLabel)
                }
                allowCached = false
                continue
            }
        }
    }

    private static func errorForExhaustion(
        terminalNonAuthError: Error?,
        sawInvalidCredentials: Bool) -> Error?
    {
        if let terminalNonAuthError { return terminalNonAuthError }
        if sawInvalidCredentials { return QoderUsageError.invalidCredentials }
        return nil
    }

    static func resolveCookieHeader(
        context: ProviderFetchContext,
        allowCached: Bool,
        skippingSourceLabels: Set<String>) throws -> QoderResolvedCookie?
    {
        if context.settings?.qoder?.cookieSource == .manual {
            let rawHeader = context.settings?.qoder?.manualCookieHeader
            let sites = try Self.sites(forManualCookieHeader: rawHeader)
            guard let manual = CookieHeaderNormalizer.normalize(rawHeader) else {
                throw QoderUsageError.missingCredentials
            }
            for site in sites {
                let sourceLabel = Self.sourceLabel(browserLabel: "manual", site: site)
                guard Self.shouldUseSourceLabel(sourceLabel, skipping: skippingSourceLabels) else {
                    continue
                }
                return QoderResolvedCookie(cookieHeader: manual, sourceLabel: sourceLabel)
            }
            return nil
        }

        #if os(macOS)
        if allowCached,
           let cached = CookieHeaderCache.load(provider: .qoder),
           !cached.cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           shouldUseSourceLabel(cached.sourceLabel, skipping: skippingSourceLabels)
        {
            return QoderResolvedCookie(
                cookieHeader: cached.cookieHeader,
                sourceLabel: cached.sourceLabel,
                isFromCache: true)
        }

        let sessions: [QoderCookieImporter.SessionInfo]
        do {
            sessions = try QoderCookieImporter.importSessions(browserDetection: context.browserDetection)
        } catch {
            throw QoderUsageError.missingCredentials
        }
        guard let session = sessions.first(where: { session in
            Self.shouldUseSourceLabel(
                Self.sourceLabel(browserLabel: session.sourceLabel, site: session.site),
                skipping: skippingSourceLabels)
        })
        else {
            return nil
        }
        guard !session.cookies.isEmpty else {
            throw QoderUsageError.missingCredentials
        }
        let sourceLabel = Self.sourceLabel(browserLabel: session.sourceLabel, site: session.site)
        CookieHeaderCache.store(
            provider: .qoder,
            cookieHeader: session.cookieHeader,
            sourceLabel: sourceLabel)
        return QoderResolvedCookie(cookieHeader: session.cookieHeader, sourceLabel: sourceLabel)
        #else
        throw QoderUsageError.missingCredentials
        #endif
    }

    static func site(forManualCookieHeader rawHeader: String?) -> QoderWebSite? {
        guard case let .site(site) = self.manualCookieRoute(rawHeader) else { return nil }
        return site
    }

    private enum ManualCookieRoute {
        case site(QoderWebSite)
        case invalid
    }

    private enum CurlHeaderHostInspection {
        case ignored
        case site(QoderWebSite)
        case invalid
    }

    private static func sites(forManualCookieHeader rawHeader: String?) throws -> [QoderWebSite] {
        switch self.manualCookieRoute(rawHeader) {
        case let .site(site):
            return [site]
        case .invalid:
            throw QoderUsageError.invalidCredentials
        }
    }

    private static func manualCookieRoute(_ rawHeader: String?) -> ManualCookieRoute {
        guard let rawHeader else { return .site(.international) }
        if let curlRoute = self.curlRequestRoute(rawHeader) {
            return curlRoute
        }
        if let httpRoute = self.httpRequestRoute(rawHeader) {
            return httpRoute
        }
        return self.plainCookieRoute(rawHeader)
    }

    private static func plainCookieRoute(_ rawHeader: String) -> ManualCookieRoute {
        var routedSite: QoderWebSite?
        for part in rawHeader.split(separator: ";") {
            let pieces = part.split(separator: "=", maxSplits: 1)
            guard pieces.count == 2 else { continue }
            let name = pieces[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard name == "domain" else { continue }
            let value = pieces[1]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard let site = self.site(forHost: value) else {
                return .invalid
            }
            if let routedSite, routedSite != site {
                return .invalid
            }
            routedSite = site
        }
        return .site(routedSite ?? .international)
    }

    private static func httpRequestRoute(_ rawHeader: String) -> ManualCookieRoute? {
        let supportedMethods = ["get", "post", "put", "patch", "delete", "head", "options"]
        let unsupportedKnownMethods = ["trace", "connect"]
        var requestSite: QoderWebSite?
        var sawRequestLine = false

        for line in rawHeader.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2 else {
                continue
            }
            let method = String(parts[0]).lowercased()
            let isHTTPVersionedLine = parts.count >= 3 && parts[2].lowercased().hasPrefix("http/")
            if unsupportedKnownMethods.contains(method) ||
                (isHTTPVersionedLine && self.isHTTPRequestMethodToken(String(parts[0])))
            {
                guard supportedMethods.contains(method) else { return .invalid }
            } else if !supportedMethods.contains(method) {
                continue
            }

            guard !sawRequestLine else { return .invalid }
            sawRequestLine = true

            let target = String(parts[1])
            if target.hasPrefix("/") {
                requestSite = nil
            } else if let site = self.site(forURLText: target) {
                requestSite = site
            } else {
                return .invalid
            }
        }

        guard sawRequestLine else { return nil }
        let hostHeaderSites = self.hostHeaderSites(rawHeader)
        guard hostHeaderSites.allSatisfy({ $0 != nil }) else { return .invalid }
        let concreteHostSites = hostHeaderSites.compactMap(\.self)
        guard concreteHostSites.dropFirst().allSatisfy({ $0 == concreteHostSites.first }) else {
            return .invalid
        }

        if let requestSite {
            if let hostSite = concreteHostSites.first, hostSite != requestSite {
                return .invalid
            }
            return .site(requestSite)
        }
        guard let hostSite = concreteHostSites.first else { return .invalid }
        return .site(hostSite)
    }

    private static func curlRequestRoute(_ rawHeader: String) -> ManualCookieRoute? {
        guard let preprocessedHeader = self.preprocessedCurlShellText(rawHeader) else {
            return self.containsCurlExecutableText(rawHeader) ? .invalid : nil
        }

        let tokens = self.shellTokens(preprocessedHeader)
        guard let curlIndex = self.curlCommandIndex(tokens) else {
            if tokens.contains(where: self.isCurlExecutableToken) {
                return .invalid
            }
            return nil
        }
        guard tokens.allSatisfy(self.isCurlTokenTextSafe) else { return .invalid }

        guard let explicitTargets = self.explicitCurlURLTargets(tokens, after: curlIndex),
              let urlTargets = self.urlTokenTargets(tokens, after: curlIndex)
        else {
            return .invalid
        }

        let targetIndices = Set(explicitTargets.map(\.index)).union(urlTargets.map(\.index))
        guard targetIndices.count == 1,
              let targetIndex = targetIndices.first
        else {
            return .invalid
        }
        let trustedIndex = tokens.index(after: curlIndex)

        let targetSite: QoderWebSite
        if let explicitTarget = explicitTargets.first(where: { $0.index == targetIndex }) {
            targetSite = explicitTarget.site
        } else if targetIndex == trustedIndex,
                  let trustedTarget = urlTargets.first(where: { $0.index == trustedIndex })
        {
            targetSite = trustedTarget.site
        } else {
            return .invalid
        }

        guard let headerSites = self.curlHeaderHostSites(tokens, after: curlIndex),
              headerSites.allSatisfy({ $0 == targetSite })
        else {
            return .invalid
        }
        return .site(targetSite)
    }

    private static func curlCommandIndex(_ tokens: [String]) -> Array<String>.Index? {
        var index = tokens.startIndex
        while index < tokens.endIndex, self.isShellAssignment(tokens[index]) {
            index = tokens.index(after: index)
        }
        guard index < tokens.endIndex else { return nil }
        guard self.isCurlExecutableToken(tokens[index]) else { return nil }
        return index
    }

    private static func isCurlExecutableToken(_ token: String) -> Bool {
        guard !token.contains("="),
              !token.contains("://")
        else {
            return false
        }
        let executable = token.split(separator: "/").last.map(String.init) ?? token
        return executable.lowercased() == "curl"
    }

    private static func containsCurlExecutableText(_ text: String) -> Bool {
        if self.shellTokens(text).contains(where: self.isCurlExecutableToken) {
            return true
        }
        let pattern = #"(^|[\s;])(?:[^\s;=]+/)?curl($|[\s;])"#
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func isShellAssignment(_ token: String) -> Bool {
        guard !token.contains(";") else { return false }
        guard let equals = token.firstIndex(of: "="),
              equals != token.startIndex
        else {
            return false
        }
        let name = token[..<equals]
        guard let first = name.first,
              first == "_" || first.isLetter
        else {
            return false
        }
        return name.allSatisfy { character in
            character == "_" || character.isLetter || character.isNumber
        }
    }

    private static func isHTTPRequestMethodToken(_ token: String) -> Bool {
        guard !token.isEmpty else { return false }
        return token.allSatisfy { character in
            character.isASCII && character.isLetter
        }
    }

    private static func explicitCurlURLTargets(
        _ tokens: [String],
        after curlIndex: Array<String>.Index) -> [(index: Array<String>.Index, site: QoderWebSite)]?
    {
        var targets: [(index: Array<String>.Index, site: QoderWebSite)] = []
        var index = tokens.index(after: curlIndex)
        while index < tokens.endIndex {
            let token = tokens[index]
            let lowercased = token.lowercased()
            if lowercased == "--url" {
                let valueIndex = tokens.index(after: index)
                guard valueIndex < tokens.endIndex,
                      let site = self.site(forURLText: tokens[valueIndex])
                else {
                    return nil
                }
                targets.append((valueIndex, site))
                index = tokens.index(after: valueIndex)
                continue
            }
            if lowercased.hasPrefix("--url=") {
                guard let site = self.site(forURLText: String(token.dropFirst("--url=".count))) else {
                    return nil
                }
                targets.append((index, site))
            }
            index = tokens.index(after: index)
        }
        return targets
    }

    private static func urlTokenTargets(
        _ tokens: [String],
        after curlIndex: Array<String>.Index) -> [(index: Array<String>.Index, site: QoderWebSite)]?
    {
        var targets: [(index: Array<String>.Index, site: QoderWebSite)] = []
        var index = tokens.index(after: curlIndex)
        while index < tokens.endIndex {
            if let site = self.site(forURLText: tokens[index]) {
                targets.append((index, site))
            } else if self.host(forURLText: tokens[index]) != nil {
                return nil
            }
            index = tokens.index(after: index)
        }
        return targets
    }

    private static func curlHeaderHostSites(
        _ tokens: [String],
        after curlIndex: Array<String>.Index) -> [QoderWebSite]?
    {
        var sites: [QoderWebSite] = []
        var index = tokens.index(after: curlIndex)
        while index < tokens.endIndex {
            let token = tokens[index]
            let lowercased = token.lowercased()
            let headerValue: String?
            if lowercased == "--config" || lowercased.hasPrefix("--config=") ||
                lowercased.hasPrefix("--expand-") ||
                lowercased == "--location-trusted" ||
                self.shortCurlOptions(token, contain: "K")
            {
                return nil
            }
            if lowercased == "--header" {
                let valueIndex = tokens.index(after: index)
                guard valueIndex < tokens.endIndex else { return nil }
                headerValue = tokens[valueIndex]
                index = tokens.index(after: valueIndex)
            } else if lowercased.hasPrefix("--header=") {
                headerValue = String(token.dropFirst("--header=".count))
                index = tokens.index(after: index)
            } else if let shortHeaderValue = self.shortCurlHeaderValue(token) {
                switch shortHeaderValue {
                case let .attached(value):
                    headerValue = value
                    index = tokens.index(after: index)
                case .nextToken:
                    let valueIndex = tokens.index(after: index)
                    guard valueIndex < tokens.endIndex else { return nil }
                    headerValue = tokens[valueIndex]
                    index = tokens.index(after: valueIndex)
                case .invalid:
                    return nil
                }
            } else {
                index = tokens.index(after: index)
                continue
            }

            guard let headerValue else { continue }
            switch self.inspectCurlHeaderHost(headerValue) {
            case .ignored:
                continue
            case let .site(site):
                sites.append(site)
            case .invalid:
                return nil
            }
        }
        return sites
    }

    private enum ShortCurlHeaderValue {
        case attached(String)
        case nextToken
        case invalid
    }

    private static func shortCurlOptions(_ token: String, contain option: Character) -> Bool {
        guard token.hasPrefix("-"),
              !token.hasPrefix("--")
        else {
            return false
        }
        return token.dropFirst().contains(option)
    }

    private static func shortCurlHeaderValue(_ token: String) -> ShortCurlHeaderValue? {
        guard token.hasPrefix("-"),
              !token.hasPrefix("--")
        else {
            return nil
        }

        let options = String(token.dropFirst())
        guard let headerOption = options.firstIndex(of: "H") else {
            return nil
        }

        let safeBundledFlags = Set("fsSL")
        let bundledFlags = options[..<headerOption]
        guard bundledFlags.allSatisfy({ safeBundledFlags.contains($0) }) else {
            return .invalid
        }

        let attached = String(options[options.index(after: headerOption)...])
        return attached.isEmpty ? .nextToken : .attached(attached)
    }

    private static func inspectCurlHeaderHost(_ headerValue: String) -> CurlHeaderHostInspection {
        let trimmed = headerValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("@")
        else {
            return .invalid
        }

        let pieces = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.count == 2 else {
            let lowercased = trimmed.lowercased()
            if lowercased == "host" || lowercased.hasPrefix("host ") || lowercased.hasPrefix("host\t") ||
                lowercased == "host;" || lowercased.hasPrefix("host;")
            {
                return .invalid
            }
            return .ignored
        }

        let name = pieces[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard name == "host" else { return .ignored }
        guard let site = self.site(forHost: String(pieces[1])) else { return .invalid }
        return .site(site)
    }

    private enum ShellQuote: Equatable {
        case single
        case double
    }

    private static func preprocessedCurlShellText(_ text: String) -> String? {
        let scalars = Array(text.unicodeScalars)
        var output = String.UnicodeScalarView()
        var index = scalars.startIndex
        var quote: ShellQuote?

        while index < scalars.endIndex {
            let scalar = scalars[index]
            let nextIndex = scalars.index(after: index)

            if scalar == "\\" {
                if quote == nil {
                    if nextIndex < scalars.endIndex, scalars[nextIndex] == "\n" {
                        index = scalars.index(after: nextIndex)
                        continue
                    }
                    if nextIndex < scalars.endIndex, scalars[nextIndex] == "\r" {
                        let afterReturn = scalars.index(after: nextIndex)
                        if afterReturn < scalars.endIndex, scalars[afterReturn] == "\n" {
                            index = scalars.index(after: afterReturn)
                            continue
                        }
                    }
                }
                if quote != .single,
                   nextIndex < scalars.endIndex,
                   self.isSupportedEscapedShellLiteral(scalars[nextIndex])
                {
                    output.append(scalar)
                    output.append(scalars[nextIndex])
                    index = scalars.index(after: nextIndex)
                    continue
                }
                if quote == .double {
                    return nil
                }
            }

            guard self.isShellScalarTextSafe(scalar) else { return nil }

            switch quote {
            case .single:
                if scalar == "'" {
                    quote = nil
                }
            case .double:
                if scalar == "\"" {
                    quote = nil
                } else if scalar == "`" || self.isUnsupportedShellDollarExpansion(in: scalars, at: index) {
                    return nil
                }
            case nil:
                if self.isUnsupportedShellControlOperator(scalar) {
                    return nil
                } else if scalar == "'" {
                    quote = .single
                } else if scalar == "\"" {
                    quote = .double
                } else if scalar == "`" ||
                    self.isUnsupportedShellDollarExpansion(in: scalars, at: index) ||
                    self.isProcessSubstitution(in: scalars, at: index)
                {
                    return nil
                }
            }

            output.append(scalar)
            index = nextIndex
        }

        return quote == nil ? String(output) : nil
    }

    private static func isUnsupportedShellControlOperator(_ scalar: UnicodeScalar) -> Bool {
        ";|&<>".unicodeScalars.contains(scalar)
    }

    private static func isSupportedEscapedShellLiteral(_ scalar: UnicodeScalar) -> Bool {
        scalar == "'" || scalar == "\"" || scalar == "\\"
    }

    private static func isShellScalarTextSafe(_ scalar: UnicodeScalar) -> Bool {
        scalar.value >= 0x20 && scalar.value != 0x7F
    }

    private static func isUnsupportedShellDollarExpansion(in scalars: [UnicodeScalar], at index: Int) -> Bool {
        guard scalars[index] == "$" else { return false }
        let nextIndex = scalars.index(after: index)
        guard nextIndex < scalars.endIndex else { return false }

        let next = scalars[nextIndex]
        if next == "'" || next == "\"" || next == "(" || next == "{" || next == "[" {
            return true
        }
        if next == "_" || next.properties.isAlphabetic || (48...57).contains(Int(next.value)) {
            return true
        }
        return "*@#?$!-".unicodeScalars.contains(next)
    }

    private static func isProcessSubstitution(in scalars: [UnicodeScalar], at index: Int) -> Bool {
        guard scalars[index] == "<" || scalars[index] == ">" else { return false }
        let nextIndex = scalars.index(after: index)
        return nextIndex < scalars.endIndex && scalars[nextIndex] == "("
    }

    private static func isCurlTokenTextSafe(_ token: String) -> Bool {
        token.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F
        }
    }

    private static func hostHeaderSites(_ rawHeader: String) -> [QoderWebSite?] {
        var sites: [QoderWebSite?] = []
        for line in rawHeader.split(whereSeparator: \.isNewline) {
            let pieces = line.split(separator: ":", maxSplits: 1)
            guard pieces.count == 2 else { continue }
            let name = pieces[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard name == "host" else { continue }
            sites.append(self.site(forHost: String(pieces[1])))
        }
        return sites
    }

    private static func host(forURLText text: String) -> String? {
        let trimmed = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        let lowercased = trimmed.lowercased()
        guard lowercased.hasPrefix("https://") || lowercased.hasPrefix("http://") else { return nil }
        return URL(string: trimmed)?.host(percentEncoded: false)?.lowercased()
    }

    private static func site(forURLText text: String) -> QoderWebSite? {
        guard let host = self.host(forURLText: text) else { return nil }
        return self.site(forHost: host)
    }

    private static func site(forHost host: String) -> QoderWebSite? {
        var normalized = String(host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .lowercased()
            .trimmingPrefix("."))
        if let portSeparator = normalized.lastIndex(of: ":") {
            let port = normalized[normalized.index(after: portSeparator)...]
            let hostname = normalized[..<portSeparator]
            guard !hostname.contains(":"),
                  !port.isEmpty,
                  port.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let portNumber = Int(port),
                  (1...65535).contains(portNumber)
            else {
                return nil
            }
            normalized = String(hostname)
        }
        switch normalized {
        case "qoder.com", "www.qoder.com":
            return .international
        case "qoder.com.cn", "www.qoder.com.cn":
            return .china
        default:
            return nil
        }
    }

    private static func shellTokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var isEscaped = false

        for character in text {
            if isEscaped {
                current.append(character)
                isEscaped = false
                continue
            }
            if character == "\\" {
                isEscaped = true
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                continue
            }
            if character.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }
            current.append(character)
        }

        if isEscaped {
            current.append("\\")
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    private static func shouldRetryManualCookieHeader(_ rawHeader: String?) -> Bool {
        ((try? self.sites(forManualCookieHeader: rawHeader).count) ?? 0) > 1
    }

    private static func sourceLabel(browserLabel: String, site: QoderWebSite) -> String {
        switch site {
        case .international:
            "\(browserLabel) / qoder.com"
        case .china:
            "\(browserLabel) / qoder.com.cn"
        }
    }

    static func site(for sourceLabel: String) -> QoderWebSite {
        if sourceLabel == "qoder.com.cn" || sourceLabel.hasSuffix(" / qoder.com.cn") {
            return .china
        }
        if sourceLabel == "qoder.com" || sourceLabel.hasSuffix(" / qoder.com") {
            return .international
        }
        return .international
    }

    private static func shouldUseSourceLabel(_ sourceLabel: String, skipping skippedLabels: Set<String>) -> Bool {
        !skippedLabels.contains(sourceLabel)
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}

struct QoderResolvedCookie {
    let cookieHeader: String
    let sourceLabel: String
    let isFromCache: Bool

    init(cookieHeader: String, sourceLabel: String, isFromCache: Bool = false) {
        self.cookieHeader = cookieHeader
        self.sourceLabel = sourceLabel
        self.isFromCache = isFromCache
    }
}
