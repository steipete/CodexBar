import CodexBarCore
import Foundation

struct ProviderAccessDetection: Identifiable, Equatable {
    enum State: Equatable {
        case detected
        case fallback
        case notFound
    }

    let provider: UsageProvider
    let state: State
    let detail: String

    var id: UsageProvider {
        self.provider
    }

    var isSelectable: Bool {
        self.state == .detected || self.state == .fallback
    }
}

struct ProviderAccessDetectionResult: Equatable {
    let accesses: [ProviderAccessDetection]

    var selectableProviders: [UsageProvider] {
        self.accesses
            .filter(\.isSelectable)
            .map(\.provider)
    }

    var suggestedProviders: [UsageProvider] {
        let detected = self.accesses
            .filter { $0.state == .detected }
            .map(\.provider)
        if !detected.isEmpty { return detected }
        return self.accesses
            .filter { $0.state == .fallback }
            .map(\.provider)
    }
}

struct ProviderAccessLocalSnapshot: Equatable {
    let codexInstalled: Bool
    let claudeInstalled: Bool
    let geminiInstalled: Bool
    let antigravityRunning: Bool
    let antigravityLoggedIn: Bool

    static func current() async -> ProviderAccessLocalSnapshot {
        let codexInstalled = BinaryLocator.resolveCodexBinary() != nil
        let claudeInstalled = BinaryLocator.resolveClaudeBinary() != nil
        let geminiInstalled = BinaryLocator.resolveGeminiBinary() != nil
        let antigravityRunning = await AntigravityStatusProbe.isRunning()
        let antigravityLoggedIn = FileManager.default.fileExists(
            atPath: AntigravityOAuthCredentialsStore().fileURL.path)

        return ProviderAccessLocalSnapshot(
            codexInstalled: codexInstalled,
            claudeInstalled: claudeInstalled,
            geminiInstalled: geminiInstalled,
            antigravityRunning: antigravityRunning,
            antigravityLoggedIn: antigravityLoggedIn)
    }
}

extension SettingsStore {
    func runInitialProviderDetectionIfNeeded(force: Bool = false) {
        guard force || (self.onboardingCompleted && !self.providerDetectionCompleted) else { return }
        LoginShellPathCache.shared.captureOnce { [weak self] _ in
            Task { @MainActor in
                await self?.applyProviderDetection()
            }
        }
    }

    func applyProviderDetection(localSnapshot: ProviderAccessLocalSnapshot? = nil) async {
        guard !self.providerDetectionCompleted else { return }
        let result = await self.detectProviderAccesses(
            includeConfiguredCredentials: false,
            localSnapshot: localSnapshot)
        self.applyProviderDetectionResult(result, selectedProviders: Set(result.suggestedProviders))
    }

    func detectProviderAccesses(
        includeConfiguredCredentials: Bool = true,
        localSnapshot: ProviderAccessLocalSnapshot? = nil) async -> ProviderAccessDetectionResult
    {
        await withCheckedContinuation { continuation in
            LoginShellPathCache.shared.captureOnce { _ in
                Task { @MainActor in
                    let result = await self.makeProviderAccessDetectionResult(
                        includeConfiguredCredentials: includeConfiguredCredentials,
                        localSnapshot: localSnapshot)
                    continuation.resume(returning: result)
                }
            }
        }
    }

    func completeOnboarding(
        detectionResult: ProviderAccessDetectionResult,
        selectedProviders: Set<UsageProvider>)
    {
        self.applyProviderDetectionResult(detectionResult, selectedProviders: selectedProviders)
        self.onboardingCompleted = true
    }

    func applyProviderDetectionResult(
        _ result: ProviderAccessDetectionResult,
        selectedProviders: Set<UsageProvider>)
    {
        let selectableProviders = Set(result.selectableProviders)
        let selectedProviders = selectedProviders.intersection(selectableProviders)
        let logger = CodexBarLog.logger(LogCategories.providerDetection)

        logger.info(
            "Provider detection enablement",
            metadata: Dictionary(uniqueKeysWithValues: result.accesses.map { access in
                (access.provider.rawValue, selectedProviders.contains(access.provider) ? "1" : "0")
            }))

        for access in result.accesses {
            self.updateProviderConfig(provider: access.provider) { entry in
                entry.enabled = access.isSelectable && selectedProviders.contains(access.provider)
            }
        }
        self.providerDetectionCompleted = true
        logger.info("Provider detection completed")
    }

    private func makeProviderAccessDetectionResult(
        includeConfiguredCredentials: Bool,
        localSnapshot: ProviderAccessLocalSnapshot?) async -> ProviderAccessDetectionResult
    {
        let localSnapshot = if let localSnapshot {
            localSnapshot
        } else {
            await ProviderAccessLocalSnapshot.current()
        }
        let configuredAccessDetails = includeConfiguredCredentials ? self.configuredAccessDetailsByProvider() : [:]
        let hasConfiguredAccess = !configuredAccessDetails.isEmpty
        let logger = CodexBarLog.logger(LogCategories.providerDetection)

        // If none installed, keep Codex enabled to match previous behavior.
        let noneInstalled = !localSnapshot.codexInstalled && !localSnapshot.claudeInstalled &&
            !localSnapshot.geminiInstalled && !localSnapshot.antigravityRunning &&
            !localSnapshot.antigravityLoggedIn && !hasConfiguredAccess
        logger.info(
            "Provider detection results",
            metadata: [
                "codexInstalled": localSnapshot.codexInstalled ? "1" : "0",
                "claudeInstalled": localSnapshot.claudeInstalled ? "1" : "0",
                "geminiInstalled": localSnapshot.geminiInstalled ? "1" : "0",
                "antigravityRunning": localSnapshot.antigravityRunning ? "1" : "0",
                "antigravityLoggedIn": localSnapshot.antigravityLoggedIn ? "1" : "0",
                "configuredAccessCount": "\(configuredAccessDetails.count)",
            ])

        let knownLocalProviders: [UsageProvider] = [.codex, .claude, .gemini, .antigravity]
        var accessesByProvider: [UsageProvider: ProviderAccessDetection] = [:]

        let codexState: ProviderAccessDetection.State = if localSnapshot.codexInstalled {
            .detected
        } else if configuredAccessDetails[.codex] != nil {
            .detected
        } else if noneInstalled {
            .fallback
        } else {
            .notFound
        }

        accessesByProvider[.codex] = ProviderAccessDetection(
            provider: .codex,
            state: codexState,
            detail: Self.combinedDetectionDetail(
                localDetail: localSnapshot.codexInstalled ? L("onboarding_provider_codex_found") : nil,
                configDetail: configuredAccessDetails[.codex],
                fallbackDetail: codexState == .fallback ? L("onboarding_provider_codex_starter_detail") :
                    L("onboarding_provider_codex_not_found_detail")))

        accessesByProvider[.claude] = ProviderAccessDetection(
            provider: .claude,
            state: (localSnapshot.claudeInstalled || configuredAccessDetails[.claude] != nil) ? .detected :
                .notFound,
            detail: Self.combinedDetectionDetail(
                localDetail: localSnapshot.claudeInstalled ? L("onboarding_provider_claude_found") : nil,
                configDetail: configuredAccessDetails[.claude],
                fallbackDetail: L("onboarding_provider_claude_not_found_detail")))

        accessesByProvider[.gemini] = ProviderAccessDetection(
            provider: .gemini,
            state: (localSnapshot.geminiInstalled || configuredAccessDetails[.gemini] != nil) ? .detected :
                .notFound,
            detail: Self.combinedDetectionDetail(
                localDetail: localSnapshot.geminiInstalled ? L("onboarding_provider_gemini_found") : nil,
                configDetail: configuredAccessDetails[.gemini],
                fallbackDetail: L("onboarding_provider_gemini_not_found_detail")))

        let antigravityDetected = localSnapshot.antigravityRunning || localSnapshot.antigravityLoggedIn ||
            configuredAccessDetails[.antigravity] != nil
        accessesByProvider[.antigravity] = ProviderAccessDetection(
            provider: .antigravity,
            state: antigravityDetected ? .detected : .notFound,
            detail: Self.combinedDetectionDetail(
                localDetail: localSnapshot.antigravityRunning || localSnapshot.antigravityLoggedIn ?
                    Self.antigravityDetectionDetail(
                        isRunning: localSnapshot.antigravityRunning,
                        isLoggedIn: localSnapshot.antigravityLoggedIn) : nil,
                configDetail: configuredAccessDetails[.antigravity],
                fallbackDetail: Self.antigravityDetectionDetail(isRunning: false, isLoggedIn: false)))

        for (provider, detail) in configuredAccessDetails where !knownLocalProviders.contains(provider) {
            accessesByProvider[provider] = ProviderAccessDetection(
                provider: provider,
                state: .detected,
                detail: detail)
        }

        var orderedProviders = knownLocalProviders
        for provider in self.config.providers.map(\.id) where !orderedProviders.contains(provider) &&
            accessesByProvider[provider] != nil
        {
            orderedProviders.append(provider)
        }

        return ProviderAccessDetectionResult(accesses: orderedProviders.compactMap { accessesByProvider[$0] })
    }

    private func configuredAccessDetailsByProvider() -> [UsageProvider: String] {
        Dictionary(uniqueKeysWithValues: self.config.providers.compactMap { providerConfig in
            guard let detail = Self.configuredAccessDetail(for: providerConfig) else { return nil }
            return (providerConfig.id, detail)
        })
    }

    private static func configuredAccessDetail(for providerConfig: ProviderConfig) -> String? {
        if let tokenAccounts = providerConfig.tokenAccounts, !tokenAccounts.accounts.isEmpty {
            return L("onboarding_provider_config_token_accounts_found")
        }
        if providerConfig.sanitizedAPIKey != nil, providerConfig.sanitizedSecretKey != nil {
            return L("onboarding_provider_config_key_pair_found")
        }
        if providerConfig.sanitizedAPIKey != nil {
            return L("onboarding_provider_config_api_key_found")
        }
        if providerConfig.sanitizedSecretKey != nil {
            return L("onboarding_provider_config_secret_found")
        }
        if providerConfig.sanitizedCookieHeader != nil {
            return L("onboarding_provider_config_cookie_found")
        }
        if providerConfig.id == .codex, providerConfig.codexActiveSource != nil {
            return L("onboarding_provider_config_codex_source_found")
        }
        return nil
    }

    private static func combinedDetectionDetail(
        localDetail: String?,
        configDetail: String?,
        fallbackDetail: String) -> String
    {
        if localDetail != nil, configDetail != nil {
            return L("onboarding_provider_config_and_local_found")
        }
        if let configDetail {
            return configDetail
        }
        if let localDetail {
            return localDetail
        }
        return fallbackDetail
    }

    private static func antigravityDetectionDetail(isRunning: Bool, isLoggedIn: Bool) -> String {
        if isRunning, isLoggedIn {
            return L("onboarding_provider_antigravity_running_auth")
        }
        if isRunning {
            return L("onboarding_provider_antigravity_running")
        }
        if isLoggedIn {
            return L("onboarding_provider_antigravity_auth_found")
        }
        return L("onboarding_provider_antigravity_not_found_detail")
    }
}
