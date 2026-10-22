import CodexBarCore
import Commander
import Foundation

extension CodexBarCLI {
    static func runConfigLogin(_ values: ParsedValues) async {
        let output = CLIOutputPreferences.from(values: values)
        // Provider-specific by design: GitHub device login is the only CLI login flow.
        guard values.options["provider"]?.last?.lowercased() == "copilot" else {
            Self.exit(code: .failure, message: "Use --provider copilot.", output: output, kind: .args)
        }
        let task = Task {
            try await Self.loginCopilot(store: CodexBarConfigStore()) { event in
                let line = if output.format == .json {
                    Self.encodeJSON(event, pretty: false) ?? ""
                } else if let url = event.verificationURI, let code = event.userCode {
                    "\(url)\n\(code)"
                } else {
                    "Connected"
                }
                FileHandle.standardOutput.write(Data("\(line)\n".utf8))
            }
        }
        let monitor = CLITerminationSignalMonitor { _ in task.cancel() }
        defer { monitor.cancel() }
        do {
            try await task.value
        } catch {
            let message = error is CancellationError
                ? URLError(.userCancelledAuthentication).localizedDescription
                : error.localizedDescription
            if output.format == .json {
                Self.printJSON(ConfigLoginEvent(status: "failed", error: message), pretty: false)
                Self.exit(code: .failure)
            }
            Self.exit(code: .failure, message: message, output: output)
        }
    }

    static func loginCopilot(
        store: CodexBarConfigStore,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        emit: (ConfigLoginEvent) -> Void) async throws
    {
        let original = try store.load()
        let originalBytes = try original?.encodedData()
        var config = original ?? .makeDefault()
        // Provider-specific by design: reuse Copilot's device flow, account identity, and config storage.
        var provider = config.providerConfig(for: .copilot) ?? ProviderConfig(id: .copilot)
        let host = provider.sanitizedEnterpriseHost
        let flow = CopilotDeviceFlow(enterpriseHost: host, transport: transport)
        let code = try await flow.requestDeviceCode()
        emit(ConfigLoginEvent(
            status: "authorization_pending",
            verificationURI: code.verificationUri,
            userCode: code.userCode,
            expiresIn: code.expiresIn))
        let token = try await flow.pollForToken(
            deviceCode: code.deviceCode, interval: code.interval, expiresIn: code.expiresIn)
        let identity = try await CopilotUsageFetcher.fetchGitHubIdentity(
            token: token, enterpriseHost: host, transport: transport)
        let issuer = CopilotUsageFetcher.apiHost(enterpriseHost: host)
        var accounts = provider.tokenAccounts?.accounts ?? []
        let existing = await CopilotAccountIdentity.matchExistingAccount(
            existingAccounts: accounts,
            identity: identity,
            label: identity.login,
            issuer: issuer,
            legacyIdentityResolver: { account in
                try? await CopilotUsageFetcher.fetchGitHubIdentity(
                    token: account.token, enterpriseHost: host, transport: transport)
            })
        let account = ProviderTokenAccount(
            id: existing?.id ?? UUID(),
            label: existing?.label ?? identity.login,
            token: token,
            addedAt: existing?.addedAt ?? Date().timeIntervalSince1970,
            lastUsed: existing?.lastUsed,
            externalIdentifier: CopilotAccountIdentity.externalIdentifier(for: identity, issuer: issuer),
            usageScope: existing?.usageScope,
            organizationID: existing?.organizationID,
            workspaceID: existing?.workspaceID,
            claudeConfigDirectory: existing?.claudeConfigDirectory,
            seatCreditEntitlement: existing?.seatCreditEntitlement,
            modelRateLimits: existing?.modelRateLimits)
        let index = accounts.firstIndex(where: { $0.id == account.id }) ?? accounts.count
        if index == accounts.count { accounts.append(account) } else { accounts[index] = account }
        provider.tokenAccounts = ProviderTokenAccountData(
            version: provider.tokenAccounts?.version ?? 1, accounts: accounts, activeIndex: index)
        provider.apiKey = nil
        provider.enabled = true
        config.setProviderConfig(provider)
        let data = try store.encodedData(for: config)
        try store.saveEncodedData(data) {
            try Task.checkCancellation()
            guard try store.load()?.encodedData() == originalBytes else {
                throw CLIArgumentError("Config changed during login. Please try again.")
            }
        }
        emit(ConfigLoginEvent(status: "authorized"))
    }
}

struct ConfigLoginEvent: Encodable {
    let status: String
    var verificationURI: String?
    var userCode: String?
    var expiresIn: Int?
    var error: String?
}
