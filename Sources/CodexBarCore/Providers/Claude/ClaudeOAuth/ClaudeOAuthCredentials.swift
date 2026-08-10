import Dispatch
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if os(macOS)
import LocalAuthentication
import Security
#endif

// swiftlint:disable type_body_length file_length
public enum ClaudeOAuthCredentialsStore {
    static let claudeKeychainService = "Claude Code-credentials"
    /// The pre-profile cache key used by released builds. New entries are scoped to the
    /// one-way credentials-profile identity so one `CLAUDE_CONFIG_DIR` cannot evict another.
    private static let legacyCacheKey = KeychainCacheStore.Key.oauth(provider: .claude)
    private static let profileCacheKeyPrefix = "claude.profile."
    public static let environmentTokenKey = "CODEXBAR_CLAUDE_OAUTH_TOKEN"
    public static let environmentScopesKey = "CODEXBAR_CLAUDE_OAUTH_SCOPES"

    // Claude CLI's OAuth client ID - this is a public identifier (not a secret).
    // It's the same client ID used by Claude Code CLI for OAuth PKCE flow.
    // Can be overridden via environment variable if Anthropic ever changes it.
    public static let defaultOAuthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    public static let environmentClientIDKey = "CODEXBAR_CLAUDE_OAUTH_CLIENT_ID"
    private static let tokenRefreshEndpoint = "https://platform.claude.com/v1/oauth/token"

    private static var oauthClientID: String {
        ProcessInfo.processInfo.environment[self.environmentClientIDKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? self.defaultOAuthClientID
    }

    static let log = CodexBarLog.logger(LogCategories.provider(.claude, scope: "usage"))
    /// The unscoped fingerprint key used by released builds. It is attributable only to the
    /// historical default credentials profile and is migrated lazily to that profile.
    private static let legacyFileFingerprintKey = "ClaudeOAuthCredentialsFileFingerprintV2"
    private static let fileFingerprintProfileSeparator = ".profile."
    private static let credentialsFileQuarantineKeyPrefix = "ClaudeOAuthCredentialsFileQuarantineV1.profile."
    private static let claudeKeychainPromptLock = NSLock()
    private enum PromptAttemptResult {
        case record(ClaudeOAuthCredentialRecord)
        case noRecord
        case failure(Error)
    }

    private struct PromptAttemptPolicy: Equatable {
        let promptMode: String
        let readStrategy: String

        static var current: PromptAttemptPolicy {
            PromptAttemptPolicy(
                promptMode: ClaudeOAuthKeychainPromptPreference.current().rawValue,
                readStrategy: ClaudeOAuthKeychainReadStrategyPreference.current().rawValue)
        }
    }

    private struct PromptAttemptOutcome {
        let generation: UInt64
        let requestID: UUID?
        let profileIdentifier: String
        let policy: PromptAttemptPolicy
        let result: PromptAttemptResult
    }

    private static let promptAttemptOutcomeLock = NSLock()
    private nonisolated(unsafe) static var lastPromptAttemptOutcome: PromptAttemptOutcome?

    private static func readPromptAttemptOutcome() -> PromptAttemptOutcome? {
        self.promptAttemptOutcomeLock.withLock { self.lastPromptAttemptOutcome }
    }

    private static func writePromptAttemptOutcome(_ outcome: PromptAttemptOutcome?) {
        self.promptAttemptOutcomeLock.withLock { self.lastPromptAttemptOutcome = outcome }
    }

    private static func invalidatePromptAttemptOutcome() {
        self.claudeKeychainPromptLock.withLock {
            _ = ClaudeOAuthKeychainAccessGate.recordPromptAttemptCompleted()
            self.writePromptAttemptOutcome(nil)
        }
    }

    private static let claudeKeychainFingerprintKey = "ClaudeOAuthClaudeKeychainFingerprintV2"
    private static let claudeKeychainFingerprintLegacyKey = "ClaudeOAuthClaudeKeychainFingerprintV1"
    private static let pendingCodexBarOAuthKeychainCacheClearKey =
        "ClaudeOAuthPendingCodexBarOAuthKeychainCacheClearV1"
    private static let directKeychainReadConsentRevocationMarkerKey =
        "ClaudeOAuthDirectKeychainReadConsentRevocationMarkerV1"
    private static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: "com.steipete.codexbar") ?? .standard
    }

    private static let pendingCodexBarOAuthKeychainCacheClearStore: ClaudeOAuthPendingCacheClearStore =
        ClaudeOAuthPendingCacheClearUserDefaultsStore(
            // The cache service is shared by release/debug apps and their CLIs, so its tombstone is shared too.
            domain: "com.steipete.codexbar",
            key: ClaudeOAuthCredentialsStore.pendingCodexBarOAuthKeychainCacheClearKey)
    private static let claudeKeychainChangeCheckLock = NSLock()
    private nonisolated(unsafe) static var lastClaudeKeychainChangeCheckAt: Date?
    private static let claudeKeychainChangeCheckMinimumInterval: TimeInterval = 60
    private static let reauthenticateHint = "Run `claude` to re-authenticate."

    struct ClaudeKeychainFingerprint: Codable, Equatable {
        let modifiedAt: Int?
        let createdAt: Int?
        let persistentRefHash: String?
    }

    private struct ClaudeKeychainCredentialEvidence {
        let credentials: ClaudeOAuthCredentials
        let persistentRefHash: String
    }

    struct CredentialsFileFingerprint: Codable, Equatable {
        let path: String
        let modifiedAtMs: Int?
        let size: Int

        private enum CodingKeys: String, CodingKey {
            case path
            case modifiedAtMs
            case size
        }

        init(path: String, modifiedAtMs: Int?, size: Int) {
            self.path = path
            self.modifiedAtMs = modifiedAtMs
            self.size = size
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // Released V2 fingerprints predate profile scoping and did not encode a path. Those
            // fingerprints could only describe the historical default Claude credentials file.
            self.path = try container.decodeIfPresent(String.self, forKey: .path)
                ?? ClaudeOAuthCredentialsStore.historicalDefaultCredentialsFilePath
            self.modifiedAtMs = try container.decodeIfPresent(Int.self, forKey: .modifiedAtMs)
            self.size = try container.decode(Int.self, forKey: .size)
        }
    }

    struct CacheEntry: Codable {
        let data: Data
        let storedAt: Date
        let owner: ClaudeOAuthCredentialOwner?
        let historyOwnerIdentifier: String?
        /// One-way ownership evidence for the Claude profile whose credentials path produced this cache.
        /// A missing value is a legacy entry. It can be migrated only to the historical default profile.
        let profileIdentifier: String?
        /// Global consent epoch at creation time. A legacy missing value is generation zero.
        let directKeychainReadConsentRevocationMarker: String?

        init(
            data: Data,
            storedAt: Date,
            owner: ClaudeOAuthCredentialOwner? = nil,
            historyOwnerIdentifier: String? = nil,
            profileIdentifier: String? = ClaudeOAuthCredentialsStore.credentialsProfileIdentifier(
                environment: ProcessInfo.processInfo.environment),
            directKeychainReadConsentRevocationMarker: String? = ClaudeOAuthCredentialsStore
                .currentDirectKeychainReadConsentRevocationMarker)
        {
            self.data = data
            self.storedAt = storedAt
            self.owner = owner
            self.historyOwnerIdentifier = ClaudeOAuthCredentials.normalizedHistoryOwnerIdentifier(
                historyOwnerIdentifier)
            self.profileIdentifier = profileIdentifier
            self.directKeychainReadConsentRevocationMarker = directKeychainReadConsentRevocationMarker
        }
    }

    #if DEBUG
    @TaskLocal private static var taskCredentialsURLOverride: URL?
    @TaskLocal private static var taskCredentialsProfileIdentifierOverride: String?
    private static let isolatedTestCredentialsURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("codexbar-tests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("credentials.json")
    #endif
    // In-memory cache (nonisolated for synchronous access)
    private static let memoryCacheLock = NSLock()
    private nonisolated(unsafe) static var cachedCredentialRecord: ClaudeOAuthCredentialRecord?
    private nonisolated(unsafe) static var cacheTimestamp: Date?
    private nonisolated(unsafe) static var cachedProfileIdentifier: String?
    private static let memoryCacheValidityDuration: TimeInterval = 1800

    private static func readMemoryCache()
        -> (record: ClaudeOAuthCredentialRecord?, timestamp: Date?, profileIdentifier: String?)
    {
        #if DEBUG
        if let store = self.taskMemoryCacheStoreOverride {
            return (store.record, store.timestamp, store.profileIdentifier)
        }
        #endif
        self.memoryCacheLock.lock()
        defer { self.memoryCacheLock.unlock() }
        return (self.cachedCredentialRecord, self.cacheTimestamp, self.cachedProfileIdentifier)
    }

    private static func readMemoryCache(
        profileIdentifier: String)
        -> (record: ClaudeOAuthCredentialRecord?, timestamp: Date?, profileIdentifier: String?)
    {
        let memory = self.readMemoryCache()
        guard memory.record != nil, memory.profileIdentifier != profileIdentifier else { return memory }
        self.writeMemoryCache(record: nil, timestamp: nil, profileIdentifier: nil)
        return (nil, nil, nil)
    }

    private static func writeMemoryCache(
        record: ClaudeOAuthCredentialRecord?,
        timestamp: Date?,
        profileIdentifier: String?)
    {
        #if DEBUG
        if let store = self.taskMemoryCacheStoreOverride {
            store.record = record
            store.timestamp = timestamp
            store.profileIdentifier = profileIdentifier
            return
        }
        #endif
        self.memoryCacheLock.lock()
        self.cachedCredentialRecord = record
        self.cacheTimestamp = timestamp
        self.cachedProfileIdentifier = profileIdentifier
        self.memoryCacheLock.unlock()
    }

    private struct CollaboratorContext {
        #if DEBUG
        let credentialsURLOverride: URL?
        let testingOverrides: TestingOverridesSnapshot
        #endif

        func run<T>(_ operation: () throws -> T) rethrows -> T {
            #if DEBUG
            try ClaudeOAuthCredentialsStore.withTestingOverridesSnapshotForTask(self.testingOverrides) {
                try ClaudeOAuthCredentialsStore
                    .withCredentialsURLOverrideForTesting(self.credentialsURLOverride) {
                        try operation()
                    }
            }
            #else
            try operation()
            #endif
        }

        func run<T>(_ operation: () async throws -> T) async rethrows -> T {
            #if DEBUG
            try await ClaudeOAuthCredentialsStore.withTestingOverridesSnapshotForTask(self.testingOverrides) {
                try await ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(
                    self.credentialsURLOverride)
                {
                    try await operation()
                }
            }
            #else
            try await operation()
            #endif
        }
    }

    private static func currentCollaboratorContext() -> CollaboratorContext {
        #if DEBUG
        CollaboratorContext(
            credentialsURLOverride: self.taskCredentialsURLOverride,
            testingOverrides: self.currentTestingOverridesSnapshotForTask)
        #else
        CollaboratorContext()
        #endif
    }

    private struct Repository {
        let context: CollaboratorContext

        func load(environment: [String: String], allowKeychainPrompt: Bool, respectKeychainPromptCooldown: Bool) throws
            -> ClaudeOAuthCredentials
        {
            try self.loadRecord(
                environment: environment,
                allowKeychainPrompt: allowKeychainPrompt,
                respectKeychainPromptCooldown: respectKeychainPromptCooldown,
                allowClaudeKeychainRepairWithoutPrompt: true).credentials
        }

        func loadRecord(
            environment: [String: String],
            allowKeychainPrompt: Bool,
            respectKeychainPromptCooldown: Bool,
            allowClaudeKeychainRepairWithoutPrompt: Bool,
            clearInvalidCache: Bool = true) throws -> ClaudeOAuthCredentialRecord
        {
            try self.context.run {
                let profileIdentifier = self.prepareCachePolicy(environment: environment)
                let shouldRespectKeychainPromptCooldownForSilentProbes =
                    respectKeychainPromptCooldown || !allowKeychainPrompt

                if let immediateRecord = try self.immediateCredentialRecord(environment: environment) {
                    return immediateRecord
                }

                let recovery = Recovery(context: self.context, profileIdentifier: profileIdentifier)
                let memory = ClaudeOAuthCredentialsStore.readMemoryCache(profileIdentifier: profileIdentifier)
                if ClaudeOAuthCredentialsStore.shouldUseCodexBarOAuthKeychainCache,
                   !ClaudeOAuthCredentialsStore.hasPendingCodexBarOAuthKeychainCacheClear(
                       profileIdentifier: profileIdentifier),
                   let cachedRecord = memory.record,
                   let timestamp = memory.timestamp,
                   memory.profileIdentifier == profileIdentifier,
                   Date().timeIntervalSince(timestamp) < ClaudeOAuthCredentialsStore.memoryCacheValidityDuration,
                   !cachedRecord.credentials.isExpired
                {
                    let owner = self.resolvedCacheOwner(
                        cachedRecord.owner,
                        credentials: cachedRecord.credentials,
                        environment: environment)
                    let record = ClaudeOAuthCredentialRecord(
                        credentials: cachedRecord.credentials,
                        owner: owner,
                        source: .memoryCache,
                        historyOwnerIdentifier: cachedRecord.historyOwnerIdentifier)
                    if recovery.shouldAttemptFreshnessSyncFromClaudeKeychain(cached: record),
                       let synced = recovery.syncWithClaudeKeychainIfChanged(
                           cached: record,
                           respectKeychainPromptCooldown: shouldRespectKeychainPromptCooldownForSilentProbes)
                    {
                        return synced
                    }
                    return record
                }

                var lastError: Error?
                var expiredRecord: ClaudeOAuthCredentialRecord?
                var cacheTemporarilyUnavailable = false

                switch ClaudeOAuthCredentialsStore.loadCodexBarOAuthKeychainCache(
                    profileIdentifier: profileIdentifier)
                {
                case let .found(entry):
                    do {
                        let creds = try ClaudeOAuthCredentials.parse(data: entry.data)
                        let owner = self.resolvedCacheOwner(
                            entry.owner ?? .claudeCLI,
                            credentials: creds,
                            environment: environment)
                        let record = ClaudeOAuthCredentialRecord(
                            credentials: creds,
                            owner: owner,
                            source: .cacheKeychain,
                            historyOwnerIdentifier: entry.historyOwnerIdentifier)
                        if creds.isExpired {
                            expiredRecord = record
                        } else {
                            if recovery.shouldAttemptFreshnessSyncFromClaudeKeychain(cached: record),
                               let synced = recovery.syncWithClaudeKeychainIfChanged(
                                   cached: record,
                                   respectKeychainPromptCooldown: shouldRespectKeychainPromptCooldownForSilentProbes)
                            {
                                return synced
                            }
                            ClaudeOAuthCredentialsStore.writeMemoryCache(
                                record: ClaudeOAuthCredentialRecord(
                                    credentials: creds,
                                    owner: owner,
                                    source: .memoryCache,
                                    historyOwnerIdentifier: record.historyOwnerIdentifier),
                                timestamp: Date(),
                                profileIdentifier: profileIdentifier)
                            return record
                        }
                    } catch {
                        lastError = self.handleInvalidCache(
                            error,
                            profileIdentifier: profileIdentifier,
                            clearInvalidCache: clearInvalidCache)
                    }
                case .invalid:
                    lastError = self.handleInvalidCache(
                        ClaudeOAuthCredentialsError.decodeFailed,
                        profileIdentifier: profileIdentifier,
                        clearInvalidCache: clearInvalidCache)
                case .temporarilyUnavailable:
                    cacheTemporarilyUnavailable = true
                    lastError = ClaudeOAuthCredentialsError.readFailed("CodexBar cache is temporarily unavailable.")
                case .missing:
                    break
                }

                do {
                    let fileData = try ClaudeOAuthCredentialsStore.loadFromFile(environment: environment)
                    let creds = try ClaudeOAuthCredentials.parse(data: fileData)
                    let record = ClaudeOAuthCredentialRecord(
                        credentials: creds,
                        owner: .claudeCLI,
                        source: .credentialsFile)
                    if creds.isExpired {
                        expiredRecord = record
                    } else {
                        ClaudeOAuthCredentialsStore.writeMemoryCache(
                            record: ClaudeOAuthCredentialRecord(
                                credentials: creds,
                                owner: .claudeCLI,
                                source: .memoryCache),
                            timestamp: Date(),
                            profileIdentifier: profileIdentifier)
                        if !cacheTemporarilyUnavailable {
                            ClaudeOAuthCredentialsStore.saveToCacheKeychain(
                                fileData,
                                owner: .claudeCLI,
                                profileIdentifier: profileIdentifier)
                        }
                        return record
                    }
                } catch let error as ClaudeOAuthCredentialsError {
                    if case .notFound = error {
                    } else {
                        lastError = error
                    }
                } catch {
                    lastError = error
                }

                if allowClaudeKeychainRepairWithoutPrompt, !allowKeychainPrompt {
                    if let repaired = recovery.repairFromClaudeKeychainWithoutPromptIfAllowed(
                        now: Date(),
                        respectKeychainPromptCooldown: shouldRespectKeychainPromptCooldownForSilentProbes,
                        allowCacheKeychainWrite: !cacheTemporarilyUnavailable)
                    {
                        return repaired
                    }
                }

                if let prompted = self.loadFromClaudeKeychainWithPromptIfAllowed(
                    allowKeychainPrompt: allowKeychainPrompt,
                    respectKeychainPromptCooldown: respectKeychainPromptCooldown,
                    allowCacheKeychainWrite: !cacheTemporarilyUnavailable,
                    environment: environment,
                    lastError: &lastError)
                {
                    return prompted
                }

                if let expiredRecord {
                    return expiredRecord
                }
                if let lastError {
                    throw lastError
                }
                throw ClaudeOAuthCredentialsError.notFound
            }
        }

        private func prepareCachePolicy(environment: [String: String]) -> String {
            let profileIdentifier = ClaudeOAuthCredentialsStore.credentialsProfileIdentifier(environment: environment)
            if !ClaudeOAuthCredentialsStore.shouldUseCodexBarOAuthKeychainCache {
                ClaudeOAuthCredentialsStore.markPendingCodexBarOAuthKeychainCacheClear(
                    profileIdentifier: profileIdentifier)
            }
            return profileIdentifier
        }

        private func handleInvalidCache(
            _ error: Error,
            profileIdentifier: String,
            clearInvalidCache: Bool) -> Error?
        {
            if clearInvalidCache {
                ClaudeOAuthCredentialsStore.clearCacheKeychain(profileIdentifier: profileIdentifier)
                return nil
            }
            return error
        }

        private func immediateCredentialRecord(environment: [String: String]) throws -> ClaudeOAuthCredentialRecord? {
            if let credentials = ClaudeOAuthCredentialsStore.loadFromEnvironment(environment) {
                return ClaudeOAuthCredentialRecord(
                    credentials: credentials,
                    owner: .environment,
                    source: .environment)
            }
            let profileIdentifier = ClaudeOAuthCredentialsStore.credentialsProfileIdentifier(
                environment: environment)
            _ = self.invalidateCacheIfCredentialsFileChanged(environment: environment)
            guard let requestID = ProviderRefreshRequestContext.id,
                  let outcome = ClaudeOAuthCredentialsStore.readPromptAttemptOutcome(),
                  outcome.requestID == requestID,
                  outcome.profileIdentifier == profileIdentifier,
                  outcome.generation == ClaudeOAuthKeychainAccessGate.promptAttemptGeneration(),
                  outcome.policy == PromptAttemptPolicy.current
            else {
                return nil
            }
            switch outcome.result {
            case let .record(record): return record
            case let .failure(error): throw error
            case .noRecord: return nil
            }
        }

        private func loadFromClaudeKeychainWithPromptIfAllowed(
            allowKeychainPrompt: Bool,
            respectKeychainPromptCooldown: Bool,
            allowCacheKeychainWrite: Bool,
            environment: [String: String],
            lastError: inout Error?) -> ClaudeOAuthCredentialRecord?
        {
            guard allowKeychainPrompt else { return nil }
            let profileIdentifier = ClaudeOAuthCredentialsStore.credentialsProfileIdentifier(
                environment: environment)
            let promptGeneration = ClaudeOAuthKeychainAccessGate.promptAttemptGeneration()
            let refreshRequestID = ProviderRefreshRequestContext.id
            #if DEBUG
            ClaudeOAuthCredentialsStore.taskBeforeClaudeKeychainPromptLockOverride?()
            #endif

            do {
                ClaudeOAuthCredentialsStore.claudeKeychainPromptLock.lock()
                defer { ClaudeOAuthCredentialsStore.claudeKeychainPromptLock.unlock() }

                // Another caller may have completed the one interactive read while this caller waited on the lock.
                // Reuse its result so an expired Keychain record cannot fan out into a queue of native dialogs.
                let currentPromptGeneration = ClaudeOAuthKeychainAccessGate.promptAttemptGeneration()
                let outcome = ClaudeOAuthCredentialsStore.readPromptAttemptOutcome()
                let policy = PromptAttemptPolicy.current
                if currentPromptGeneration != promptGeneration ||
                    (refreshRequestID != nil && outcome?.requestID == refreshRequestID),
                    outcome?.profileIdentifier == profileIdentifier,
                    outcome?.policy == policy
                {
                    guard outcome?.generation == currentPromptGeneration else { return nil }
                    switch outcome?.result {
                    case let .record(record): return record
                    case let .failure(error):
                        lastError = error
                        return nil
                    case .noRecord, .none: return nil
                    }
                }

                if let cachedRecord = self.validCachedCredentialAfterWaitingForPromptLock(
                    environment: environment,
                    profileIdentifier: profileIdentifier)
                {
                    return cachedRecord
                }

                let shouldApplyPromptCooldown =
                    ClaudeOAuthCredentialsStore.isPromptPolicyApplicable && respectKeychainPromptCooldown
                guard !shouldApplyPromptCooldown || ClaudeOAuthKeychainAccessGate.shouldAllowPrompt() else {
                    return nil
                }
                let promptMode = ClaudeOAuthKeychainPromptPreference.current()
                guard ClaudeOAuthCredentialsStore.shouldAllowClaudeCodeKeychainAccess(mode: promptMode) else {
                    return nil
                }
                var promptAttemptResult = PromptAttemptResult.noRecord
                defer {
                    let generation = ClaudeOAuthKeychainAccessGate.recordPromptAttemptCompleted()
                    ClaudeOAuthCredentialsStore.writePromptAttemptOutcome(PromptAttemptOutcome(
                        generation: generation,
                        requestID: refreshRequestID,
                        profileIdentifier: profileIdentifier,
                        policy: policy,
                        result: promptAttemptResult))
                }

                do {
                    let record = try self.readClaudeKeychainInteractively(
                        promptMode: promptMode,
                        allowKeychainPrompt: allowKeychainPrompt,
                        respectKeychainPromptCooldown: respectKeychainPromptCooldown,
                        allowCacheKeychainWrite: allowCacheKeychainWrite,
                        profileIdentifier: profileIdentifier)
                    if let record {
                        promptAttemptResult = .record(record)
                    }
                    return record
                } catch {
                    promptAttemptResult = .failure(error)
                    throw error
                }
            } catch let error as ClaudeOAuthCredentialsError {
                if case .notFound = error {
                } else {
                    lastError = error
                }
            } catch {
                lastError = error
            }
            return nil
        }

        private func validCachedCredentialAfterWaitingForPromptLock(
            environment: [String: String],
            profileIdentifier: String) -> ClaudeOAuthCredentialRecord?
        {
            let memory = ClaudeOAuthCredentialsStore.readMemoryCache(profileIdentifier: profileIdentifier)
            if ClaudeOAuthCredentialsStore.shouldUseCodexBarOAuthKeychainCache,
               !ClaudeOAuthCredentialsStore.hasPendingCodexBarOAuthKeychainCacheClear(
                   profileIdentifier: profileIdentifier),
               let cachedRecord = memory.record,
               let timestamp = memory.timestamp,
               memory.profileIdentifier == profileIdentifier,
               Date().timeIntervalSince(timestamp) < ClaudeOAuthCredentialsStore.memoryCacheValidityDuration,
               !cachedRecord.credentials.isExpired
            {
                let owner = self.resolvedCacheOwner(
                    cachedRecord.owner,
                    credentials: cachedRecord.credentials,
                    environment: environment)
                return ClaudeOAuthCredentialRecord(
                    credentials: cachedRecord.credentials,
                    owner: owner,
                    source: .memoryCache,
                    historyOwnerIdentifier: cachedRecord.historyOwnerIdentifier)
            }
            guard case let .found(entry) = ClaudeOAuthCredentialsStore.loadCodexBarOAuthKeychainCache(
                profileIdentifier: profileIdentifier),
                let credentials = try? ClaudeOAuthCredentials.parse(data: entry.data),
                !credentials.isExpired
            else {
                return nil
            }
            let owner = self.resolvedCacheOwner(
                entry.owner ?? .claudeCLI,
                credentials: credentials,
                environment: environment)
            return ClaudeOAuthCredentialRecord(
                credentials: credentials,
                owner: owner,
                source: .cacheKeychain,
                historyOwnerIdentifier: entry.historyOwnerIdentifier)
        }

        private func readClaudeKeychainInteractively(
            promptMode: ClaudeOAuthKeychainPromptMode,
            allowKeychainPrompt: Bool,
            respectKeychainPromptCooldown: Bool,
            allowCacheKeychainWrite: Bool,
            profileIdentifier: String) throws -> ClaudeOAuthCredentialRecord?
        {
            #if DEBUG
            if let readOverride = ClaudeOAuthCredentialsStore.taskInteractiveClaudeKeychainReadOverride {
                return try self.recordClaudeKeychainData(
                    readOverride(),
                    allowCacheKeychainWrite: allowCacheKeychainWrite,
                    profileIdentifier: profileIdentifier)
            }
            #endif

            let shouldPreferSecurityCLI = ClaudeOAuthCredentialsStore.shouldPreferSecurityCLIKeychainRead()
            if shouldPreferSecurityCLI,
               let keychainData = ClaudeOAuthCredentialsStore.loadFromClaudeKeychainViaSecurityCLIIfEnabled(
                   interaction: ProviderInteractionContext.current)
            {
                return try self.recordClaudeKeychainData(
                    keychainData,
                    allowCacheKeychainWrite: allowCacheKeychainWrite,
                    profileIdentifier: profileIdentifier)
            }

            var securityFrameworkPromptMode = promptMode
            if shouldPreferSecurityCLI {
                securityFrameworkPromptMode = ClaudeOAuthKeychainPromptPreference.securityFrameworkFallbackMode()
                let decision = ClaudeOAuthCredentialsStore.securityFrameworkFallbackPromptDecision(
                    promptMode: securityFrameworkPromptMode,
                    allowKeychainPrompt: allowKeychainPrompt,
                    respectKeychainPromptCooldown: respectKeychainPromptCooldown)
                ClaudeOAuthCredentialsStore.log.debug(
                    "Claude keychain Security.framework fallback prompt policy evaluated",
                    metadata: [
                        "reader": "securityFrameworkFallback",
                        "fallbackPromptMode": securityFrameworkPromptMode.rawValue,
                        "fallbackPromptAllowed": "\(decision.allowed)",
                        "fallbackBlockedReason": decision.blockedReason ?? "none",
                    ])
                guard decision.allowed else { return nil }
            }

            if ClaudeOAuthCredentialsStore.shouldNotifyClaudeKeychainPreAlert() {
                ClaudeOAuthKeychainPreAlertGate.presentIfNeeded {
                    KeychainPromptHandler.notifyIfHandled(
                        KeychainPromptContext(
                            kind: .claudeOAuth,
                            service: ClaudeOAuthCredentialsStore.claudeKeychainService,
                            account: nil))
                }
            }
            let keychainData: Data = if shouldPreferSecurityCLI {
                try ClaudeOAuthCredentialsStore.loadFromClaudeKeychainUsingSecurityFramework(
                    promptMode: securityFrameworkPromptMode,
                    allowKeychainPrompt: true)
            } else {
                try ClaudeOAuthCredentialsStore.loadFromClaudeKeychain()
            }
            return try self.recordClaudeKeychainData(
                keychainData,
                allowCacheKeychainWrite: allowCacheKeychainWrite,
                profileIdentifier: profileIdentifier)
        }

        private func recordClaudeKeychainData(
            _ keychainData: Data,
            allowCacheKeychainWrite: Bool,
            profileIdentifier: String) throws -> ClaudeOAuthCredentialRecord
        {
            let credentials = try ClaudeOAuthCredentials.parse(data: keychainData)
            let record = ClaudeOAuthCredentialRecord(
                credentials: credentials,
                owner: .claudeCLI,
                source: .claudeKeychain)
            ClaudeOAuthCredentialsStore.writeMemoryCache(
                record: ClaudeOAuthCredentialRecord(
                    credentials: credentials,
                    owner: .claudeCLI,
                    source: .memoryCache),
                timestamp: Date(),
                profileIdentifier: profileIdentifier)
            if allowCacheKeychainWrite {
                ClaudeOAuthCredentialsStore.saveToCacheKeychain(
                    keychainData,
                    owner: .claudeCLI,
                    profileIdentifier: profileIdentifier)
            }
            return record
        }

        func resolvedCacheOwner(
            _ owner: ClaudeOAuthCredentialOwner,
            credentials: ClaudeOAuthCredentials,
            environment: [String: String]) -> ClaudeOAuthCredentialOwner
        {
            guard owner == .codexbar else { return owner }
            guard self.hasClaudeCLIStorageWithoutPrompt(
                matching: credentials,
                environment: environment)
            else { return owner }
            // Claude Code rotates refresh tokens; evidence of CLI storage or a logged-in Claude Code config
            // keeps the chain CLI-owned. Only positive absence lets CodexBar keep its mirror chain alive.
            return .claudeCLI
        }

        private func hasClaudeCLIStorageWithoutPrompt(
            matching credentials: ClaudeOAuthCredentials,
            environment: [String: String]) -> Bool
        {
            if ClaudeOAuthCredentialsStore.currentFileFingerprint(environment: environment) != nil {
                return true
            }

            let keychainMatch: ClaudeKeychainCredentialMatch =
                if ClaudeOAuthKeychainPromptPreference.storedMode() == .never {
                    .unavailable
                } else {
                    ClaudeOAuthCredentialsStore.claudeKeychainCredentialMatchWithoutPrompt(for: credentials)
                }

            switch keychainMatch {
            case .matched, .mismatch:
                return true
            case .absent:
                return false
            case .unavailable, .notApplicable:
                // The keychain cannot tell us anything, so Claude's plaintext config decides —
                // and only positive proof of a signed-out CLI releases the chain to CodexBar.
                // Indeterminate evidence (unreadable/malformed config) stays CLI-owned: never
                // rotate a chain we cannot prove we own.
                switch ClaudeAccountProfile.configOwnershipEvidence(environment: environment) {
                case .signedIn, .indeterminate:
                    return true
                case .signedOut:
                    return false
                }
            }
        }

        @discardableResult
        func invalidateCacheIfCredentialsFileChanged(
            environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool
        {
            self.context.run {
                let current = ClaudeOAuthCredentialsStore.currentFileFingerprint(environment: environment)
                let profileIdentifier = ClaudeOAuthCredentialsStore.credentialsProfileIdentifier(
                    environment: environment)
                let stored = ClaudeOAuthCredentialsStore.loadFileFingerprint(profileIdentifier: profileIdentifier)
                guard current != stored else { return false }
                ClaudeOAuthCredentialsStore.log.info("Claude OAuth credentials file changed; invalidating cache")
                ClaudeOAuthCredentialsStore.invalidatePromptAttemptOutcome()

                ClaudeOAuthCredentialsStore.writeMemoryCache(
                    record: nil,
                    timestamp: nil,
                    profileIdentifier: nil)

                var shouldClearKeychainCache = false
                var shouldSaveFileFingerprint = true
                if ClaudeOAuthCredentialsStore.shouldUseCodexBarOAuthKeychainCache {
                    if ClaudeOAuthCredentialsStore.hasPendingCodexBarOAuthKeychainCacheClear(
                        profileIdentifier: profileIdentifier)
                    {
                        // Pending legacy cleanup is distinct from a pending profile-key clear. A file change must
                        // still invalidate the profile entry before a later load can return it as authoritative.
                        shouldClearKeychainCache = true
                    } else if let current {
                        if let modifiedAtMs = current.modifiedAtMs {
                            let modifiedAt = Date(
                                timeIntervalSince1970: TimeInterval(Double(modifiedAtMs) / 1000.0))
                            switch ClaudeOAuthCredentialsStore.loadCodexBarOAuthKeychainCache(
                                profileIdentifier: profileIdentifier)
                            {
                            case let .found(entry):
                                if entry.storedAt < modifiedAt {
                                    shouldClearKeychainCache = true
                                }
                            case .missing, .invalid:
                                shouldClearKeychainCache = true
                            case .temporarilyUnavailable:
                                shouldClearKeychainCache = false
                                shouldSaveFileFingerprint = false
                            }
                        } else {
                            shouldClearKeychainCache = true
                        }
                    } else {
                        shouldClearKeychainCache = true
                    }
                } else {
                    ClaudeOAuthCredentialsStore.markPendingCodexBarOAuthKeychainCacheClear(
                        profileIdentifier: profileIdentifier)
                }

                if shouldClearKeychainCache {
                    if !ClaudeOAuthCredentialsStore.clearCacheKeychain(profileIdentifier: profileIdentifier) {
                        shouldSaveFileFingerprint = false
                    }
                }
                if shouldSaveFileFingerprint {
                    ClaudeOAuthCredentialsStore.saveFileFingerprint(current, profileIdentifier: profileIdentifier)
                }
                return true
            }
        }

        func invalidateCache(environment: [String: String]) {
            self.context.run {
                let profileIdentifier = ClaudeOAuthCredentialsStore.credentialsProfileIdentifier(
                    environment: environment)
                ClaudeOAuthCredentialsStore.invalidatePromptAttemptOutcome()
                ClaudeOAuthCredentialsStore.writeMemoryCache(
                    record: nil,
                    timestamp: nil,
                    profileIdentifier: nil)
                ClaudeOAuthCredentialsStore.clearCacheKeychain(profileIdentifier: profileIdentifier)
            }
        }

        func hasCachedCredentials(environment: [String: String]) -> Bool {
            self.context.run {
                func isRefreshableOrValid(_ record: ClaudeOAuthCredentialRecord) -> Bool {
                    let creds = record.credentials
                    if !creds.isExpired {
                        return true
                    }
                    switch record.owner {
                    case .claudeCLI:
                        return true
                    case .codexbar:
                        let refreshToken = creds.refreshToken?.trimmingCharacters(
                            in: .whitespacesAndNewlines) ?? ""
                        return !refreshToken.isEmpty
                    case .environment:
                        return false
                    }
                }

                if let creds = ClaudeOAuthCredentialsStore.loadFromEnvironment(environment),
                   isRefreshableOrValid(
                       ClaudeOAuthCredentialRecord(
                           credentials: creds,
                           owner: .environment,
                           source: .environment))
                {
                    return true
                }

                let profileIdentifier = ClaudeOAuthCredentialsStore.credentialsProfileIdentifier(
                    environment: environment)
                let memory = ClaudeOAuthCredentialsStore.readMemoryCache(profileIdentifier: profileIdentifier)
                if ClaudeOAuthCredentialsStore.shouldUseCodexBarOAuthKeychainCache,
                   !ClaudeOAuthCredentialsStore.hasPendingCodexBarOAuthKeychainCacheClear(
                       profileIdentifier: profileIdentifier),
                   let timestamp = memory.timestamp,
                   let cached = memory.record,
                   memory.profileIdentifier == profileIdentifier,
                   Date().timeIntervalSince(timestamp) < ClaudeOAuthCredentialsStore.memoryCacheValidityDuration,
                   isRefreshableOrValid(cached)
                {
                    return true
                }

                switch ClaudeOAuthCredentialsStore.loadCodexBarOAuthKeychainCache(
                    profileIdentifier: profileIdentifier)
                {
                case let .found(entry):
                    guard let creds = try? ClaudeOAuthCredentials.parse(data: entry.data) else { return false }
                    let record = ClaudeOAuthCredentialRecord(
                        credentials: creds,
                        owner: entry.owner ?? .claudeCLI,
                        source: .cacheKeychain)
                    return isRefreshableOrValid(record)
                case .temporarilyUnavailable:
                    if ClaudeOAuthCredentialsStore.hasPendingCodexBarOAuthKeychainCacheClear(
                        profileIdentifier: profileIdentifier)
                    {
                        break
                    }
                    return true
                case .missing, .invalid:
                    break
                }

                if let fileData = try? ClaudeOAuthCredentialsStore.loadFromFile(environment: environment),
                   let creds = try? ClaudeOAuthCredentials.parse(data: fileData),
                   isRefreshableOrValid(
                       ClaudeOAuthCredentialRecord(
                           credentials: creds,
                           owner: .claudeCLI,
                           source: .credentialsFile))
                {
                    return true
                }
                return false
            }
        }

        func hasClaudeKeychainCredentialsWithoutPrompt() -> Bool {
            self.context.run {
                #if os(macOS)
                let mode = ClaudeOAuthKeychainPromptPreference.current()
                guard ClaudeOAuthCredentialsStore.shouldAllowClaudeCodeKeychainAccess(
                    mode: mode,
                    allowKeychainPrompt: false) else { return false }
                if ClaudeOAuthCredentialsStore.loadFromClaudeKeychainViaSecurityCLIIfEnabled(
                    interaction: ProviderInteractionContext.current) != nil
                {
                    return true
                }

                let fallbackPromptMode = ClaudeOAuthKeychainPromptPreference.securityFrameworkFallbackMode()
                guard ClaudeOAuthCredentialsStore.shouldAllowClaudeCodeKeychainAccess(
                    mode: fallbackPromptMode,
                    allowKeychainPrompt: false)
                else {
                    return false
                }
                if ProviderInteractionContext.current == .background,
                   !ClaudeOAuthKeychainAccessGate.shouldAllowPrompt()
                {
                    return false
                }
                #if DEBUG
                if let store = ClaudeOAuthCredentialsStore.taskClaudeKeychainOverrideStore,
                   let data = store.data
                {
                    return (try? ClaudeOAuthCredentials.parse(data: data)) != nil
                }
                if let data = ClaudeOAuthCredentialsStore.taskClaudeKeychainDataOverride {
                    return (try? ClaudeOAuthCredentials.parse(data: data)) != nil
                }
                #endif

                var query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: ClaudeOAuthCredentialsStore.claudeKeychainService,
                    kSecMatchLimit as String: kSecMatchLimitOne,
                    kSecReturnAttributes as String: true,
                ]
                KeychainNoUIQuery.apply(to: &query)

                let (status, _, durationMs) = ClaudeOAuthKeychainQueryTiming.copyMatching(query)
                if ClaudeOAuthKeychainQueryTiming
                    .backoffIfSlowNoUIQuery(
                        durationMs,
                        ClaudeOAuthCredentialsStore.claudeKeychainService,
                        ClaudeOAuthCredentialsStore.log)
                {
                    return false
                }
                switch status {
                case errSecSuccess, errSecInteractionNotAllowed:
                    return true
                case errSecUserCanceled, errSecAuthFailed, errSecNoAccessForItem:
                    ClaudeOAuthKeychainAccessGate.recordDenied()
                    return false
                default:
                    return false
                }
                #else
                return false
                #endif
            }
        }
    }

    private struct Recovery {
        let context: CollaboratorContext
        let profileIdentifier: String

        func shouldAttemptFreshnessSyncFromClaudeKeychain(cached: ClaudeOAuthCredentialRecord) -> Bool {
            guard !cached.credentials.isExpired else { return false }
            guard cached.owner == .claudeCLI else { return false }
            guard ClaudeOAuthCredentialsStore.keychainAccessAllowed else { return false }

            let mode = ClaudeOAuthKeychainPromptPreference.storedMode()
            switch mode {
            case .never:
                return false
            case .onlyOnUserAction:
                if ProviderInteractionContext.current != .userInitiated {
                    if ProcessInfo.processInfo.environment["CODEXBAR_DEBUG_CLAUDE_OAUTH_FLOW"] == "1" {
                        ClaudeOAuthCredentialsStore.log.debug(
                            "Claude OAuth keychain freshness sync skipped (background)",
                            metadata: ["promptMode": mode.rawValue, "owner": String(describing: cached.owner)])
                    }
                    return false
                }
                return true
            case .always:
                return true
            }
        }

        func syncWithClaudeKeychainIfChanged(
            cached: ClaudeOAuthCredentialRecord,
            respectKeychainPromptCooldown: Bool,
            now: Date = Date()) -> ClaudeOAuthCredentialRecord?
        {
            #if os(macOS)
            let mode = ClaudeOAuthKeychainPromptPreference.current()
            guard ClaudeOAuthCredentialsStore
                .shouldAllowClaudeCodeKeychainAccess(mode: mode, allowKeychainPrompt: false) else { return nil }
            if ClaudeOAuthCredentialsStore.isPromptPolicyApplicable,
               respectKeychainPromptCooldown,
               !ClaudeOAuthKeychainAccessGate.shouldAllowPrompt(now: now)
            {
                return nil
            }

            if ClaudeOAuthCredentialsStore.shouldShowClaudeKeychainPreAlert() {
                return nil
            }

            if !ClaudeOAuthCredentialsStore.shouldCheckClaudeKeychainChange(now: now) {
                return nil
            }

            guard let currentFingerprint = ClaudeOAuthCredentialsStore.currentClaudeKeychainFingerprintWithoutPrompt()
            else {
                return nil
            }
            let storedFingerprint = ClaudeOAuthCredentialsStore.loadClaudeKeychainFingerprint()
            guard currentFingerprint != storedFingerprint else { return nil }

            do {
                guard let data = try ClaudeOAuthCredentialsStore.loadFromClaudeKeychainNonInteractive() else {
                    return nil
                }
                guard let keychainCreds = try? ClaudeOAuthCredentials.parse(data: data) else {
                    ClaudeOAuthCredentialsStore.saveClaudeKeychainFingerprint(currentFingerprint)
                    return nil
                }
                ClaudeOAuthCredentialsStore.saveClaudeKeychainFingerprint(currentFingerprint)

                guard keychainCreds.accessToken != cached.credentials.accessToken else { return nil }
                if keychainCreds.isExpired, !cached.credentials.isExpired {
                    return nil
                }

                ClaudeOAuthCredentialsStore.log.info("Claude keychain credentials changed; syncing OAuth cache")
                let synced = ClaudeOAuthCredentialRecord(
                    credentials: keychainCreds,
                    owner: .claudeCLI,
                    source: .claudeKeychain)
                ClaudeOAuthCredentialsStore.writeMemoryCache(
                    record: ClaudeOAuthCredentialRecord(
                        credentials: keychainCreds,
                        owner: .claudeCLI,
                        source: .memoryCache),
                    timestamp: now,
                    profileIdentifier: self.profileIdentifier)
                ClaudeOAuthCredentialsStore.saveToCacheKeychain(
                    data,
                    owner: .claudeCLI,
                    profileIdentifier: self.profileIdentifier)
                return synced
            } catch let error as ClaudeOAuthCredentialsError {
                if case let .keychainError(status) = error,
                   status == Int(errSecUserCanceled)
                   || status == Int(errSecAuthFailed)
                   || status == Int(errSecInteractionNotAllowed)
                   || status == Int(errSecNoAccessForItem)
                {
                    ClaudeOAuthKeychainAccessGate.recordDenied(now: now)
                }
                return nil
            } catch {
                return nil
            }
            #else
            _ = cached
            _ = respectKeychainPromptCooldown
            _ = now
            return nil
            #endif
        }

        func repairFromClaudeKeychainWithoutPromptIfAllowed(
            now: Date,
            respectKeychainPromptCooldown: Bool,
            allowCacheKeychainWrite: Bool = true) -> ClaudeOAuthCredentialRecord?
        {
            #if os(macOS)
            let mode = ClaudeOAuthKeychainPromptPreference.current()
            guard ClaudeOAuthCredentialsStore
                .shouldAllowClaudeCodeKeychainAccess(mode: mode, allowKeychainPrompt: false) else { return nil }

            if ClaudeOAuthCredentialsStore.shouldShowClaudeKeychainPreAlert() {
                return nil
            }

            if ClaudeOAuthCredentialsStore.isPromptPolicyApplicable,
               respectKeychainPromptCooldown,
               ProviderInteractionContext.current != .userInitiated,
               !ClaudeOAuthKeychainAccessGate.shouldAllowPrompt(now: now)
            {
                return nil
            }

            do {
                if ClaudeOAuthCredentialsStore.shouldPreferSecurityCLIKeychainRead(),
                   let securityData = ClaudeOAuthCredentialsStore.loadFromClaudeKeychainViaSecurityCLIIfEnabled(
                       interaction: ProviderInteractionContext.current),
                   !securityData.isEmpty
                {
                    guard let creds = try? ClaudeOAuthCredentials.parse(data: securityData) else { return nil }
                    if creds.isExpired {
                        return ClaudeOAuthCredentialRecord(
                            credentials: creds,
                            owner: .claudeCLI,
                            source: .claudeKeychain)
                    }

                    ClaudeOAuthCredentialsStore.writeMemoryCache(
                        record: ClaudeOAuthCredentialRecord(
                            credentials: creds,
                            owner: .claudeCLI,
                            source: .memoryCache),
                        timestamp: now,
                        profileIdentifier: self.profileIdentifier)
                    if allowCacheKeychainWrite {
                        ClaudeOAuthCredentialsStore.saveToCacheKeychain(
                            securityData,
                            owner: .claudeCLI,
                            profileIdentifier: self.profileIdentifier)
                    }

                    ClaudeOAuthCredentialsStore.log.info(
                        "Claude keychain credentials loaded without prompt; syncing OAuth cache",
                        metadata: ["interaction": ProviderInteractionContext.current == .userInitiated
                            ? "user" : "background"])
                    return ClaudeOAuthCredentialRecord(
                        credentials: creds,
                        owner: .claudeCLI,
                        source: .claudeKeychain)
                }

                guard let data = try ClaudeOAuthCredentialsStore.loadFromClaudeKeychainNonInteractive(),
                      !data.isEmpty
                else {
                    return nil
                }
                let fingerprint = ClaudeOAuthCredentialsStore.currentClaudeKeychainFingerprintWithoutPrompt()
                guard let creds = try? ClaudeOAuthCredentials.parse(data: data) else {
                    ClaudeOAuthCredentialsStore.saveClaudeKeychainFingerprint(fingerprint)
                    return nil
                }

                if creds.isExpired {
                    ClaudeOAuthCredentialsStore.saveClaudeKeychainFingerprint(fingerprint)
                    return ClaudeOAuthCredentialRecord(
                        credentials: creds,
                        owner: .claudeCLI,
                        source: .claudeKeychain)
                }

                ClaudeOAuthCredentialsStore.saveClaudeKeychainFingerprint(fingerprint)
                ClaudeOAuthCredentialsStore.writeMemoryCache(
                    record: ClaudeOAuthCredentialRecord(
                        credentials: creds,
                        owner: .claudeCLI,
                        source: .memoryCache),
                    timestamp: now,
                    profileIdentifier: self.profileIdentifier)
                if allowCacheKeychainWrite {
                    ClaudeOAuthCredentialsStore.saveToCacheKeychain(
                        data,
                        owner: .claudeCLI,
                        profileIdentifier: self.profileIdentifier)
                }

                ClaudeOAuthCredentialsStore.log.info(
                    "Claude keychain credentials loaded without prompt; syncing OAuth cache",
                    metadata: ["interaction": ProviderInteractionContext.current == .userInitiated
                        ? "user" : "background"])
                return ClaudeOAuthCredentialRecord(
                    credentials: creds,
                    owner: .claudeCLI,
                    source: .claudeKeychain)
            } catch let error as ClaudeOAuthCredentialsError {
                if case let .keychainError(status) = error,
                   status == Int(errSecUserCanceled)
                   || status == Int(errSecAuthFailed)
                   || status == Int(errSecInteractionNotAllowed)
                   || status == Int(errSecNoAccessForItem)
                {
                    ClaudeOAuthKeychainAccessGate.recordDenied(now: now)
                }
                return nil
            } catch {
                return nil
            }
            #else
            _ = now
            _ = respectKeychainPromptCooldown
            return nil
            #endif
        }

        @discardableResult
        func syncFromClaudeKeychainWithoutPrompt(now: Date = Date()) -> Bool {
            self.context.run {
                #if os(macOS)
                let mode = ClaudeOAuthKeychainPromptPreference.current()
                guard ClaudeOAuthCredentialsStore.shouldAllowClaudeCodeKeychainAccess(
                    mode: mode,
                    allowKeychainPrompt: false) else { return false }

                if let data = ClaudeOAuthCredentialsStore.loadFromClaudeKeychainViaSecurityCLIIfEnabled(
                    interaction: ProviderInteractionContext.current),
                    !data.isEmpty
                {
                    if let creds = try? ClaudeOAuthCredentials.parse(data: data), !creds.isExpired {
                        ClaudeOAuthCredentialsStore.writeMemoryCache(
                            record: ClaudeOAuthCredentialRecord(
                                credentials: creds,
                                owner: .claudeCLI,
                                source: .memoryCache),
                            timestamp: now,
                            profileIdentifier: self.profileIdentifier)
                        ClaudeOAuthCredentialsStore.saveToCacheKeychain(
                            data,
                            owner: .claudeCLI,
                            profileIdentifier: self.profileIdentifier)
                        return true
                    }
                }

                let fallbackPromptMode = ClaudeOAuthKeychainPromptPreference.securityFrameworkFallbackMode()
                guard ClaudeOAuthCredentialsStore.shouldAllowClaudeCodeKeychainAccess(
                    mode: fallbackPromptMode,
                    allowKeychainPrompt: false)
                else {
                    return false
                }

                if ProviderInteractionContext.current == .background,
                   !ClaudeOAuthKeychainAccessGate.shouldAllowPrompt(now: now)
                {
                    return false
                }

                #if DEBUG
                let override = ClaudeOAuthCredentialsStore.taskClaudeKeychainOverrideStore?.data
                    ?? ClaudeOAuthCredentialsStore.taskClaudeKeychainDataOverride
                if let override,
                   !override.isEmpty,
                   let creds = try? ClaudeOAuthCredentials.parse(data: override),
                   !creds.isExpired
                {
                    ClaudeOAuthCredentialsStore.saveClaudeKeychainFingerprint(
                        ClaudeOAuthCredentialsStore.currentClaudeKeychainFingerprintWithoutPrompt())
                    ClaudeOAuthCredentialsStore.writeMemoryCache(
                        record: ClaudeOAuthCredentialRecord(
                            credentials: creds,
                            owner: .claudeCLI,
                            source: .memoryCache),
                        timestamp: now,
                        profileIdentifier: self.profileIdentifier)
                    ClaudeOAuthCredentialsStore.saveToCacheKeychain(
                        override,
                        owner: .claudeCLI,
                        profileIdentifier: self.profileIdentifier)
                    return true
                }
                #endif

                if ClaudeOAuthCredentialsStore.shouldShowClaudeKeychainPreAlert() {
                    return false
                }

                if let candidate = ClaudeOAuthCredentialsStore.claudeKeychainCandidatesWithoutPrompt(
                    promptMode: fallbackPromptMode).first,
                    let data = try? ClaudeOAuthCredentialsStore.loadClaudeKeychainData(
                        candidate: candidate,
                        allowKeychainPrompt: false),
                    !data.isEmpty
                {
                    let fingerprint = ClaudeKeychainFingerprint(
                        modifiedAt: candidate.modifiedAt.map { Int($0.timeIntervalSince1970) },
                        createdAt: candidate.createdAt.map { Int($0.timeIntervalSince1970) },
                        persistentRefHash: ClaudeOAuthCredentialsStore.sha256Prefix(candidate.persistentRef))

                    if let creds = try? ClaudeOAuthCredentials.parse(data: data), !creds.isExpired {
                        ClaudeOAuthCredentialsStore.saveClaudeKeychainFingerprint(fingerprint)
                        ClaudeOAuthCredentialsStore.writeMemoryCache(
                            record: ClaudeOAuthCredentialRecord(
                                credentials: creds,
                                owner: .claudeCLI,
                                source: .memoryCache),
                            timestamp: now,
                            profileIdentifier: self.profileIdentifier)
                        ClaudeOAuthCredentialsStore.saveToCacheKeychain(
                            data,
                            owner: .claudeCLI,
                            profileIdentifier: self.profileIdentifier)
                        return true
                    }

                    ClaudeOAuthCredentialsStore.saveClaudeKeychainFingerprint(fingerprint)
                }

                let legacyData = try? ClaudeOAuthCredentialsStore.loadClaudeKeychainLegacyData(
                    allowKeychainPrompt: false,
                    promptMode: fallbackPromptMode)
                if let legacyData,
                   !legacyData.isEmpty,
                   let creds = try? ClaudeOAuthCredentials.parse(data: legacyData),
                   !creds.isExpired
                {
                    ClaudeOAuthCredentialsStore.saveClaudeKeychainFingerprint(
                        ClaudeOAuthCredentialsStore.currentClaudeKeychainFingerprintWithoutPrompt())
                    ClaudeOAuthCredentialsStore.writeMemoryCache(
                        record: ClaudeOAuthCredentialRecord(
                            credentials: creds,
                            owner: .claudeCLI,
                            source: .memoryCache),
                        timestamp: now,
                        profileIdentifier: self.profileIdentifier)
                    ClaudeOAuthCredentialsStore.saveToCacheKeychain(
                        legacyData,
                        owner: .claudeCLI,
                        profileIdentifier: self.profileIdentifier)
                    return true
                }

                return false
                #else
                _ = now
                return false
                #endif
            }
        }
    }

    private struct Refresher {
        let context: CollaboratorContext
        let profileIdentifier: String
        let environment: [String: String]

        func refreshAccessToken(
            refreshToken: String,
            existingScopes: [String],
            existingRateLimitTier: String?,
            existingSubscriptionType: String? = nil,
            historyOwnerIdentifier: String?) async throws -> ClaudeOAuthCredentials
        {
            try await self.context.run {
                let newCredentials = try await self.refreshAccessTokenCore(
                    refreshToken: refreshToken,
                    existingScopes: existingScopes,
                    existingRateLimitTier: existingRateLimitTier,
                    existingSubscriptionType: existingSubscriptionType)

                ClaudeOAuthCredentialsStore.saveRefreshedCredentialsToCache(
                    newCredentials,
                    historyOwnerIdentifier: historyOwnerIdentifier,
                    profileIdentifier: self.profileIdentifier)
                ClaudeOAuthCredentialsStore.writeMemoryCache(
                    record: ClaudeOAuthCredentialRecord(
                        credentials: newCredentials,
                        owner: .codexbar,
                        source: .memoryCache,
                        historyOwnerIdentifier: historyOwnerIdentifier),
                    timestamp: Date(),
                    profileIdentifier: self.profileIdentifier)
                ClaudeOAuthRefreshFailureGate.recordSuccess(environment: self.environment)

                return newCredentials
            }
        }

        private func refreshAccessTokenCore(
            refreshToken: String,
            existingScopes: [String],
            existingRateLimitTier: String?,
            existingSubscriptionType: String?) async throws -> ClaudeOAuthCredentials
        {
            let refreshTokenHash = ClaudeOAuthCredentialsStore.sha256Hex(Data(refreshToken.utf8))
            guard ClaudeOAuthRefreshFailureGate.shouldAttempt(
                environment: self.environment,
                refreshTokenHash: refreshTokenHash)
            else {
                let status = ClaudeOAuthRefreshFailureGate.currentBlockStatus(environment: self.environment)
                let message = switch status {
                case .terminal:
                    "Claude OAuth refresh blocked until auth changes. \(ClaudeOAuthCredentialsStore.reauthenticateHint)"
                case .transient:
                    "Claude OAuth refresh temporarily backed off due to prior failures; will retry automatically."
                case nil:
                    "Claude OAuth refresh temporarily suppressed due to prior failures; will retry automatically."
                }
                throw ClaudeOAuthCredentialsError.refreshFailed(message)
            }

            guard let url = URL(string: ClaudeOAuthCredentialsStore.tokenRefreshEndpoint) else {
                throw ClaudeOAuthCredentialsError.refreshFailed("Invalid token endpoint URL")
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 30
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            var components = URLComponents()
            components.queryItems = [
                URLQueryItem(name: "grant_type", value: "refresh_token"),
                URLQueryItem(name: "refresh_token", value: refreshToken),
                URLQueryItem(name: "client_id", value: ClaudeOAuthCredentialsStore.oauthClientID),
            ]
            request.httpBody = (components.percentEncodedQuery ?? "").data(using: .utf8)

            let response = try await ProviderHTTPClient.shared.response(for: request)
            let data = response.data
            guard response.statusCode == 200 else {
                if let disposition = ClaudeOAuthCredentialsStore.refreshFailureDisposition(
                    statusCode: response.statusCode,
                    data: data)
                {
                    let oauthError = ClaudeOAuthCredentialsStore.extractOAuthErrorCode(from: data)
                    ClaudeOAuthCredentialsStore.log.info(
                        "Claude OAuth refresh rejected",
                        metadata: [
                            "httpStatus": "\(response.statusCode)",
                            "oauthError": oauthError ?? "nil",
                            "disposition": disposition.rawValue,
                        ])

                    switch disposition {
                    case .terminalInvalidGrant:
                        ClaudeOAuthRefreshFailureGate.recordTerminalAuthFailure(
                            environment: self.environment,
                            refreshTokenHash: refreshTokenHash)
                        Repository(context: self.context).invalidateCache(environment: self.environment)
                        let message = "HTTP \(response.statusCode) invalid_grant. " +
                            ClaudeOAuthCredentialsStore.reauthenticateHint
                        throw ClaudeOAuthCredentialsError.refreshFailed(
                            message)
                    case .transientBackoff:
                        ClaudeOAuthRefreshFailureGate.recordTransientFailure(
                            environment: self.environment,
                            refreshTokenHash: refreshTokenHash)
                        let suffix = oauthError.map { " (\($0))" } ?? ""
                        throw ClaudeOAuthCredentialsError.refreshFailed("HTTP \(response.statusCode)\(suffix)")
                    }
                }
                throw ClaudeOAuthCredentialsError.refreshFailed("HTTP \(response.statusCode)")
            }

            let tokenResponse = try JSONDecoder().decode(TokenRefreshResponse.self, from: data)
            let expiresAt = Date(timeIntervalSinceNow: TimeInterval(tokenResponse.expiresIn))

            return ClaudeOAuthCredentials(
                accessToken: tokenResponse.accessToken,
                refreshToken: tokenResponse.refreshToken ?? refreshToken,
                expiresAt: expiresAt,
                scopes: existingScopes,
                rateLimitTier: existingRateLimitTier,
                subscriptionType: existingSubscriptionType)
        }
    }

    public static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        allowKeychainPrompt: Bool = true,
        respectKeychainPromptCooldown: Bool = false) throws -> ClaudeOAuthCredentials
    {
        let context = self.currentCollaboratorContext()
        return try Repository(context: context).load(
            environment: environment,
            allowKeychainPrompt: allowKeychainPrompt,
            respectKeychainPromptCooldown: respectKeychainPromptCooldown)
    }

    public static func loadRecord(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        allowKeychainPrompt: Bool = true,
        respectKeychainPromptCooldown: Bool = false,
        allowClaudeKeychainRepairWithoutPrompt: Bool = true,
        clearInvalidCache: Bool = true) throws -> ClaudeOAuthCredentialRecord
    {
        let context = self.currentCollaboratorContext()
        return try Repository(context: context).loadRecord(
            environment: environment,
            allowKeychainPrompt: allowKeychainPrompt,
            respectKeychainPromptCooldown: respectKeychainPromptCooldown,
            allowClaudeKeychainRepairWithoutPrompt: allowClaudeKeychainRepairWithoutPrompt,
            clearInvalidCache: clearInvalidCache)
    }

    #if DEBUG
    static func resolvedCacheOwnerForTesting(
        _ owner: ClaudeOAuthCredentialOwner,
        credentials: ClaudeOAuthCredentials,
        environment: [String: String]) -> ClaudeOAuthCredentialOwner
    {
        Repository(context: self.currentCollaboratorContext()).resolvedCacheOwner(
            owner,
            credentials: credentials,
            environment: environment)
    }

    static func claudeKeychainCredentialMatchForTesting(
        credentials: ClaudeOAuthCredentials) -> ClaudeKeychainCredentialMatch
    {
        self.claudeKeychainCredentialMatchWithoutPrompt(for: credentials)
    }
    #endif

    /// Async version of load that handles expired tokens based on credential ownership.
    /// - Claude CLI-owned credentials delegate refresh to Claude CLI.
    /// - CodexBar-owned credentials refresh directly via token endpoint.
    public static func loadWithAutoRefresh(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        allowKeychainPrompt: Bool = true,
        respectKeychainPromptCooldown: Bool = false) async throws -> ClaudeOAuthCredentials
    {
        try await self.loadRecordWithAutoRefresh(
            environment: environment,
            allowKeychainPrompt: allowKeychainPrompt,
            respectKeychainPromptCooldown: respectKeychainPromptCooldown).credentials
    }

    /// Record-preserving variant used when callers must distinguish the credential that actually won routing.
    public static func loadRecordWithAutoRefresh(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        allowKeychainPrompt: Bool = true,
        respectKeychainPromptCooldown: Bool = false,
        allowClaudeKeychainRepairWithoutPrompt: Bool = true,
        clearInvalidCache: Bool = true) async throws -> ClaudeOAuthCredentialRecord
    {
        let context = self.currentCollaboratorContext()
        let repository = Repository(context: context)
        let refresher = Refresher(
            context: context,
            profileIdentifier: self.credentialsProfileIdentifier(environment: environment),
            environment: environment)
        let record = try repository.loadRecord(
            environment: environment,
            allowKeychainPrompt: allowKeychainPrompt,
            respectKeychainPromptCooldown: respectKeychainPromptCooldown,
            allowClaudeKeychainRepairWithoutPrompt: allowClaudeKeychainRepairWithoutPrompt,
            clearInvalidCache: clearInvalidCache)
        let credentials = record.credentials
        let now = Date()
        var expiryMetadata = credentials.diagnosticsMetadata(now: now)
        expiryMetadata["source"] = record.source.rawValue
        expiryMetadata["owner"] = record.owner.rawValue
        expiryMetadata["allowKeychainPrompt"] = "\(allowKeychainPrompt)"
        expiryMetadata["respectPromptCooldown"] = "\(respectKeychainPromptCooldown)"
        expiryMetadata["readStrategy"] = ClaudeOAuthKeychainReadStrategyPreference.current().rawValue

        let isExpired: Bool = if let expiresAt = credentials.expiresAt {
            now >= expiresAt
        } else {
            true
        }

        // If not expired, return as-is
        guard isExpired else {
            self.log.debug("Claude OAuth credentials loaded for usage", metadata: expiryMetadata)
            return record
        }

        self.log.info("Claude OAuth credentials considered expired", metadata: expiryMetadata)

        switch record.owner {
        case .claudeCLI:
            if ProviderInteractionContext.current != .userInitiated,
               ClaudeOAuthCredentialsStore.shouldBlockSelectedProfileForMcpOnlyClaudeKeychain(
                   interaction: ProviderInteractionContext.current,
                   environment: environment)
            {
                self.log.warning(
                    "Claude OAuth credentials expired; Claude keychain has MCP OAuth state only",
                    metadata: expiryMetadata)
                throw ClaudeOAuthCredentialsError.mcpOAuthOnlyKeychain
            }
            self.log.info(
                "Claude OAuth credentials expired; delegating refresh to Claude CLI",
                metadata: expiryMetadata)
            throw ClaudeOAuthCredentialsError.refreshDelegatedToClaudeCLI
        case .environment:
            self.log.warning("Environment OAuth token expired and cannot be auto-refreshed")
            throw ClaudeOAuthCredentialsError.noRefreshToken
        case .codexbar:
            break
        }

        // Try to refresh if we have a refresh token.
        guard let refreshToken = credentials.refreshToken, !refreshToken.isEmpty else {
            self.log.warning("Token expired but no refresh token available")
            throw ClaudeOAuthCredentialsError.noRefreshToken
        }
        self.log.info("Access token expired, attempting auto-refresh")

        do {
            let refreshed = try await refresher.refreshAccessToken(
                refreshToken: refreshToken,
                existingScopes: credentials.scopes,
                existingRateLimitTier: credentials.rateLimitTier,
                existingSubscriptionType: credentials.subscriptionType,
                historyOwnerIdentifier: record.historyOwnerIdentifier)
            self.log.info("Token refresh successful, expires in \(refreshed.expiresIn ?? 0) seconds")
            return ClaudeOAuthCredentialRecord(
                credentials: refreshed,
                owner: .codexbar,
                source: .memoryCache,
                historyOwnerIdentifier: record.historyOwnerIdentifier)
        } catch {
            self.log.error("Token refresh failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Save refreshed credentials to CodexBar's keychain cache
    private static func saveRefreshedCredentialsToCache(
        _ credentials: ClaudeOAuthCredentials,
        historyOwnerIdentifier: String?,
        profileIdentifier: String)
    {
        var oauth: [String: Any] = [
            "accessToken": credentials.accessToken,
            "expiresAt": (credentials.expiresAt?.timeIntervalSince1970 ?? 0) * 1000,
            "scopes": credentials.scopes,
        ]

        if let refreshToken = credentials.refreshToken {
            oauth["refreshToken"] = refreshToken
        }
        if let rateLimitTier = credentials.rateLimitTier {
            oauth["rateLimitTier"] = rateLimitTier
        }
        if let subscriptionType = credentials.subscriptionType {
            oauth["subscriptionType"] = subscriptionType
        }

        let oauthData: [String: Any] = ["claudeAiOauth": oauth]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: oauthData) else {
            self.log.error("Failed to serialize refreshed credentials for cache")
            return
        }

        self.saveToCacheKeychain(
            jsonData,
            owner: .codexbar,
            historyOwnerIdentifier: historyOwnerIdentifier,
            profileIdentifier: profileIdentifier)
        self.log.debug("Saved refreshed credentials to CodexBar keychain cache")
    }

    /// Response from the OAuth token refresh endpoint
    private struct TokenRefreshResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Int
        let tokenType: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case tokenType = "token_type"
        }
    }

    public static func loadFromFile(
        environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Data
    {
        guard !self.isCurrentCredentialsFileQuarantinedForOAuth(environment: environment) else {
            throw ClaudeOAuthCredentialsError.notFound
        }
        let url = self.credentialsFileURL(environment: environment)
        do {
            return try Data(contentsOf: url)
        } catch {
            if (error as NSError).code == NSFileReadNoSuchFileError {
                throw ClaudeOAuthCredentialsError.notFound
            }
            throw ClaudeOAuthCredentialsError.readFailed(error.localizedDescription)
        }
    }

    static func hasSelectedProfileOAuthCredentialsFile(environment: [String: String]) -> Bool {
        guard let data = try? self.loadFromFile(environment: environment) else { return false }
        return (try? ClaudeOAuthCredentials.parse(data: data)) != nil
    }

    public static func credentialsFileFingerprintToken(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        guard let fingerprint = self.currentFileFingerprint(environment: environment) else { return nil }
        let modifiedAt = fingerprint.modifiedAtMs.map(String.init) ?? "nil"
        return "\(fingerprint.path):\(modifiedAt):\(fingerprint.size)"
    }

    /// Rejects the selected profile's current credentials file until its fingerprint changes. This prevents an
    /// account-mismatched OAuth record from re-entering through the file after its memory/Keychain cache is cleared.
    @discardableResult
    public static func quarantineCurrentCredentialsFileForOAuth(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool
    {
        let profileIdentifier = self.credentialsProfileIdentifier(environment: environment)
        guard let fingerprint = self.currentFileFingerprint(environment: environment) else {
            self.saveQuarantinedCredentialsFileFingerprint(nil, profileIdentifier: profileIdentifier)
            return false
        }
        self.saveQuarantinedCredentialsFileFingerprint(fingerprint, profileIdentifier: profileIdentifier)
        return true
    }

    /// Returns true only while the selected profile still exposes the exact file fingerprint that was rejected.
    /// A rewrite, removal, or profile switch automatically releases the quarantine.
    public static func isCurrentCredentialsFileQuarantinedForOAuth(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool
    {
        let profileIdentifier = self.credentialsProfileIdentifier(environment: environment)
        guard let quarantined = self.loadQuarantinedCredentialsFileFingerprint(
            profileIdentifier: profileIdentifier)
        else { return false }
        let current = self.currentFileFingerprint(environment: environment)
        guard current == quarantined else {
            self.saveQuarantinedCredentialsFileFingerprint(nil, profileIdentifier: profileIdentifier)
            return false
        }
        return true
    }

    public static func authFingerprintToken(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String
    {
        let file = self.credentialsFileFingerprintToken(environment: environment) ?? "nil"
        let keychain = self.claudeKeychainFingerprintToken() ?? "nil"
        return "file=\(file)|keychain=\(keychain)"
    }

    public static func consumeClaudeKeychainFingerprintChangeWithoutPrompt() -> Bool {
        let current: ClaudeKeychainFingerprint?
        switch self.probeClaudeKeychainFingerprintWithoutPrompt() {
        case .unavailable:
            return false
        case let .value(fingerprint):
            current = fingerprint
        }
        let stored = self.loadClaudeKeychainFingerprint()
        guard current != stored else { return false }
        self.saveClaudeKeychainFingerprint(current)
        return true
    }

    public static func claudeKeychainFingerprintChangedWithoutConsuming() -> Bool {
        let current: ClaudeKeychainFingerprint?
        switch self.probeClaudeKeychainFingerprintWithoutPrompt() {
        case .unavailable:
            return false
        case let .value(fingerprint):
            current = fingerprint
        }
        return current != self.loadClaudeKeychainFingerprint()
    }

    public static func claudeKeychainFingerprintToken() -> String? {
        let fingerprint: ClaudeKeychainFingerprint? = switch self.probeClaudeKeychainFingerprintWithoutPrompt() {
        case .unavailable:
            self.loadClaudeKeychainFingerprint()
        case let .value(probed):
            probed
        }
        guard let fingerprint else { return nil }
        let modifiedAt = fingerprint.modifiedAt.map(String.init) ?? "nil"
        let createdAt = fingerprint.createdAt.map(String.init) ?? "nil"
        let persistentRefHash = fingerprint.persistentRefHash ?? "nil"
        return "\(modifiedAt):\(createdAt):\(persistentRefHash)"
    }

    /// Returns the current Claude Code Keychain item's opaque persistent-reference hash without
    /// falling back to a stored fingerprint. History ownership must prefer no identity over a
    /// potentially stale identity when a non-interactive Keychain probe is unavailable.
    public static func claudeKeychainPersistentRefHashWithoutPrompt() -> String? {
        switch self.probeClaudeKeychainFingerprintWithoutPrompt() {
        case .unavailable:
            nil
        case let .value(fingerprint):
            fingerprint?.persistentRefHash
        }
    }

    /// Returns the current Keychain item's persistent-reference hash only when it owns the credential
    /// that actually won OAuth routing. Token material is compared in memory and is never hashed or persisted.
    public static func matchingClaudeKeychainPersistentRefHashWithoutPrompt(
        for record: ClaudeOAuthCredentialRecord) -> String?
    {
        self.claudeKeychainCredentialMatchWithoutPrompt(for: record).persistentRefHash
    }

    static func claudeKeychainCredentialMatchWithoutPrompt(
        for record: ClaudeOAuthCredentialRecord) -> ClaudeKeychainCredentialMatch
    {
        guard record.owner == .claudeCLI else { return .notApplicable }
        return self.claudeKeychainCredentialMatchWithoutPrompt(for: record.credentials)
    }

    private static func claudeKeychainCredentialMatchWithoutPrompt(
        for credentials: ClaudeOAuthCredentials) -> ClaudeKeychainCredentialMatch
    {
        let evidence: ClaudeKeychainCredentialEvidence
        switch self.newestClaudeKeychainCredentialEvidenceWithoutPrompt() {
        case .unavailable:
            return .unavailable
        case .value(nil):
            return .absent
        case let .value(value?):
            evidence = value
        }
        guard evidence.credentials.accessToken == credentials.accessToken else {
            return .mismatch
        }
        return .matched(persistentRefHash: evidence.persistentRefHash)
    }

    private static func matchingClaudeKeychainPersistentRefHash(
        for record: ClaudeOAuthCredentialRecord,
        evidence: ClaudeKeychainCredentialEvidence?) -> String?
    {
        guard let evidence,
              evidence.credentials.accessToken == record.credentials.accessToken
        else {
            return nil
        }
        return evidence.persistentRefHash
    }

    private static func newestClaudeKeychainCredentialEvidenceWithoutPrompt()
        -> ClaudeKeychainProbe<ClaudeKeychainCredentialEvidence?>
    {
        guard self.keychainAccessAllowed else { return .unavailable }
        #if DEBUG
        if let store = self.taskClaudeKeychainOverrideStore {
            guard store.data != nil || store.fingerprint != nil else { return .value(nil) }
            return self.makeClaudeKeychainCredentialEvidence(
                data: store.data,
                persistentRefHash: store.fingerprint?.persistentRefHash).map { .value($0) } ?? .unavailable
        }
        let overrideData = self.taskClaudeKeychainDataOverride
        let overrideFingerprint = self.taskClaudeKeychainFingerprintOverride
        if overrideData != nil || overrideFingerprint != nil {
            return self.makeClaudeKeychainCredentialEvidence(
                data: overrideData,
                persistentRefHash: overrideFingerprint?.persistentRefHash).map { .value($0) } ?? .unavailable
        }
        if self.taskSecurityCLIReadOverride != nil {
            // A security(1) result cannot be bound to a persistent reference without an exact candidate read.
            return .unavailable
        }
        #endif

        #if os(macOS)
        let promptMode = ClaudeOAuthKeychainPromptPreference.current()
        let newest: ClaudeKeychainCandidate?
        switch self.claudeKeychainCandidatesProbeWithoutPrompt(promptMode: promptMode) {
        case .unavailable:
            return .unavailable
        case let .value(candidates):
            if let first = candidates.first {
                newest = first
            } else {
                switch self.claudeKeychainLegacyCandidateProbeWithoutPrompt(promptMode: promptMode) {
                case .unavailable:
                    return .unavailable
                case let .value(candidate):
                    newest = candidate
                }
            }
        }
        guard let newest else { return .value(nil) }
        guard let persistentRefHash = self.sha256Prefix(newest.persistentRef),
              let data = try? self.loadClaudeKeychainData(
                  candidate: newest,
                  allowKeychainPrompt: false,
                  promptMode: promptMode)
        else {
            return .unavailable
        }
        guard let evidence = self.makeClaudeKeychainCredentialEvidence(
            data: data,
            persistentRefHash: persistentRefHash)
        else { return .unavailable }
        return .value(evidence)
        #else
        return .unavailable
        #endif
    }

    private static func makeClaudeKeychainCredentialEvidence(
        data: Data?,
        persistentRefHash: String?) -> ClaudeKeychainCredentialEvidence?
    {
        guard let data,
              let persistentRefHash,
              let credentials = try? ClaudeOAuthCredentials.parse(data: data)
        else {
            return nil
        }
        return ClaudeKeychainCredentialEvidence(
            credentials: credentials,
            persistentRefHash: persistentRefHash)
    }

    #if DEBUG
    static func _matchingClaudeKeychainPersistentRefHashForTesting(
        record: ClaudeOAuthCredentialRecord,
        candidateCredentials: ClaudeOAuthCredentials,
        persistentRefHash: String) -> String?
    {
        self.matchingClaudeKeychainPersistentRefHash(
            for: record,
            evidence: ClaudeKeychainCredentialEvidence(
                credentials: candidateCredentials,
                persistentRefHash: persistentRefHash))
    }
    #endif

    private enum ClaudeKeychainProbe<Value> {
        case unavailable
        case value(Value)
    }

    @discardableResult
    public static func invalidateCacheIfCredentialsFileChanged(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool
    {
        Repository(context: self.currentCollaboratorContext())
            .invalidateCacheIfCredentialsFileChanged(environment: environment)
    }

    /// Invalidate the active Claude profile's credentials cache (call after login/logout).
    public static func invalidateCache(
        environment: [String: String] = ProcessInfo.processInfo.environment)
    {
        Repository(context: self.currentCollaboratorContext()).invalidateCache(environment: environment)
    }

    /// Retires every Claude CLI-owned cache written before consent was revoked. Profile cache keys are one-way
    /// hashes, so an epoch guard is the only bounded way to cover previously used `CLAUDE_CONFIG_DIR` values.
    public static func revokeDirectKeychainReadConsent(
        environment: [String: String] = ProcessInfo.processInfo.environment)
    {
        self.advanceDirectKeychainReadConsentRevocationMarker()
        self.invalidateCache(environment: environment)
    }

    /// Check if CodexBar has cached credentials (in memory or keychain cache)
    public static func hasCachedCredentials(environment: [String: String] = ProcessInfo.processInfo
        .environment) -> Bool
    {
        Repository(context: self.currentCollaboratorContext()).hasCachedCredentials(environment: environment)
    }

    public static func hasClaudeKeychainCredentialsWithoutPrompt() -> Bool {
        Repository(context: self.currentCollaboratorContext()).hasClaudeKeychainCredentialsWithoutPrompt()
    }

    private static func shouldCheckClaudeKeychainChange(now: Date = Date()) -> Bool {
        #if DEBUG
        // Unit tests can supply TaskLocal overrides for the Claude keychain data/fingerprint. Those tests often run
        // concurrently with other suites, so the global throttle becomes nondeterministic. When an override is
        // present, bypass the throttle so test expectations don't depend on unrelated activity.
        if self.taskClaudeKeychainOverrideStore != nil || self.taskClaudeKeychainFingerprintOverride != nil {
            return true
        }
        #endif

        self.claudeKeychainChangeCheckLock.lock()
        defer { self.claudeKeychainChangeCheckLock.unlock() }
        if let last = self.lastClaudeKeychainChangeCheckAt,
           now.timeIntervalSince(last) < self.claudeKeychainChangeCheckMinimumInterval
        {
            return false
        }
        self.lastClaudeKeychainChangeCheckAt = now
        return true
    }

    private static func loadClaudeKeychainFingerprint() -> ClaudeKeychainFingerprint? {
        #if DEBUG
        if let store = taskClaudeKeychainFingerprintStoreOverride {
            return store.fingerprint
        }
        #endif
        // Proactively remove the legacy V1 key (it included the keychain account string, which can be identifying).
        UserDefaults.standard.removeObject(forKey: self.claudeKeychainFingerprintLegacyKey)

        guard let data = UserDefaults.standard.data(forKey: self.claudeKeychainFingerprintKey) else {
            return nil
        }
        return try? JSONDecoder().decode(ClaudeKeychainFingerprint.self, from: data)
    }

    private static func saveClaudeKeychainFingerprint(_ fingerprint: ClaudeKeychainFingerprint?) {
        #if DEBUG
        if let store = taskClaudeKeychainFingerprintStoreOverride {
            store.fingerprint = fingerprint
            return
        }
        #endif
        // Proactively remove the legacy V1 key (it included the keychain account string, which can be identifying).
        UserDefaults.standard.removeObject(forKey: self.claudeKeychainFingerprintLegacyKey)

        guard let fingerprint else {
            UserDefaults.standard.removeObject(forKey: self.claudeKeychainFingerprintKey)
            return
        }
        if let data = try? JSONEncoder().encode(fingerprint) {
            UserDefaults.standard.set(data, forKey: self.claudeKeychainFingerprintKey)
        }
    }

    private static func currentClaudeKeychainFingerprintWithoutPrompt() -> ClaudeKeychainFingerprint? {
        switch self.probeClaudeKeychainFingerprintWithoutPrompt() {
        case .unavailable:
            nil
        case let .value(fingerprint):
            fingerprint
        }
    }

    private static func probeClaudeKeychainFingerprintWithoutPrompt()
    -> ClaudeKeychainProbe<ClaudeKeychainFingerprint?> {
        let mode = ClaudeOAuthKeychainPromptPreference.current()
        #if DEBUG
        if let store = taskClaudeKeychainOverrideStore {
            return .value(store.fingerprint)
        }
        if let override = taskClaudeKeychainFingerprintOverride {
            return .value(override)
        }
        #endif
        guard self.shouldAllowClaudeCodeKeychainAccess(mode: mode, allowKeychainPrompt: false)
        else { return .unavailable }
        if self.isPromptPolicyApplicable,
           ProviderInteractionContext.current == .background,
           !ClaudeOAuthKeychainAccessGate.shouldAllowPrompt()
        {
            return .unavailable
        }
        #if os(macOS)
        let candidatesProbe = self.claudeKeychainCandidatesProbeWithoutPrompt(promptMode: mode)
        let newest: ClaudeKeychainCandidate?
        switch candidatesProbe {
        case .unavailable:
            return .unavailable
        case let .value(candidates):
            if let first = candidates.first {
                newest = first
            } else {
                switch self.claudeKeychainLegacyCandidateProbeWithoutPrompt(promptMode: mode) {
                case .unavailable:
                    return .unavailable
                case let .value(candidate):
                    newest = candidate
                }
            }
        }
        guard let newest else { return .value(nil) }

        let modifiedAt = newest.modifiedAt.map { Int($0.timeIntervalSince1970) }
        let createdAt = newest.createdAt.map { Int($0.timeIntervalSince1970) }
        let persistentRefHash = Self.sha256Prefix(newest.persistentRef)
        return .value(ClaudeKeychainFingerprint(
            modifiedAt: modifiedAt,
            createdAt: createdAt,
            persistentRefHash: persistentRefHash))
        #else
        return .unavailable
        #endif
    }

    static func currentClaudeKeychainFingerprintWithoutPromptForAuthGate() -> ClaudeKeychainFingerprint? {
        self.currentClaudeKeychainFingerprintWithoutPrompt()
    }

    public static func currentCredentialsFileFingerprintWithoutPromptForAuthGate(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        guard let fingerprint = self.currentFileFingerprint(environment: environment) else { return nil }
        let modifiedAt = fingerprint.modifiedAtMs ?? 0
        return "\(fingerprint.path):\(modifiedAt):\(fingerprint.size)"
    }

    private static func loadFromClaudeKeychainNonInteractive(
        readStrategy: ClaudeOAuthKeychainReadStrategy = ClaudeOAuthKeychainReadStrategyPreference.current())
        throws -> Data?
    {
        #if os(macOS)
        let fallbackPromptMode = ClaudeOAuthKeychainPromptPreference.securityFrameworkFallbackMode(
            readStrategy: readStrategy)
        if let data = self.loadFromClaudeKeychainViaSecurityCLIIfEnabled(
            interaction: ProviderInteractionContext.current,
            readStrategy: readStrategy)
        {
            return data
        }

        // For experimental strategy, apply the stored policy before no-UI Security.framework fallback probes.
        guard self.shouldAllowClaudeCodeKeychainAccess(mode: fallbackPromptMode, allowKeychainPrompt: false)
        else { return nil }

        #if DEBUG
        if let store = taskClaudeKeychainOverrideStore {
            return store.data
        }
        if let override = taskClaudeKeychainDataOverride {
            return override
        }
        #endif

        // Keep semantics aligned with fingerprinting: if there are multiple entries, we only ever consult the newest
        // candidate (same as currentClaudeKeychainFingerprintWithoutPrompt()) to avoid syncing from a different item.
        let candidates = self.claudeKeychainCandidatesWithoutPrompt(promptMode: fallbackPromptMode)
        if let newest = candidates.first {
            if let data = try self.loadClaudeKeychainData(candidate: newest, allowKeychainPrompt: false),
               !data.isEmpty
            {
                return data
            }
            return nil
        }

        let legacyData = try self.loadClaudeKeychainLegacyData(
            allowKeychainPrompt: false,
            promptMode: fallbackPromptMode)
        if let legacyData, !legacyData.isEmpty {
            return legacyData
        }
        return nil
        #else
        return nil
        #endif
    }

    static func readRawClaudeKeychainPayloadViaSecurityFrameworkWithoutPrompt() -> Data? {
        #if os(macOS)
        guard self.keychainAccessAllowed else { return nil }
        #if DEBUG
        if let store = self.taskClaudeKeychainOverrideStore {
            return store.data
        }
        if let override = self.taskClaudeKeychainDataOverride {
            return override
        }
        #endif

        // This probe must work under the default `onlyOnUserAction` policy, but must never show Keychain UI.
        // The candidate and data queries both use KeychainNoUIQuery; `.always` only bypasses the prompt-policy gate.
        switch self.claudeKeychainCandidatesProbeWithoutPrompt(
            promptMode: .always,
            enforcePromptPolicy: false)
        {
        case .unavailable:
            return nil
        case let .value(candidates):
            if let newest = candidates.first {
                return try? self.loadClaudeKeychainData(
                    candidate: newest,
                    allowKeychainPrompt: false,
                    promptMode: .always)
            }
        }
        return try? self.loadClaudeKeychainLegacyData(
            allowKeychainPrompt: false,
            promptMode: .always)
        #else
        return nil
        #endif
    }

    public static func loadFromClaudeKeychain() throws -> Data {
        guard self.shouldAllowClaudeCodeKeychainAccess(mode: ClaudeOAuthKeychainPromptPreference.current()) else {
            throw ClaudeOAuthCredentialsError.notFound
        }
        #if DEBUG
        if let store = taskClaudeKeychainOverrideStore, let override = store.data {
            return override
        }
        if let override = taskClaudeKeychainDataOverride {
            return override
        }
        #endif
        if let data = self.loadFromClaudeKeychainViaSecurityCLIIfEnabled(
            interaction: ProviderInteractionContext.current)
        {
            return data
        }
        if self.shouldPreferSecurityCLIKeychainRead() {
            let fallbackPromptMode = ClaudeOAuthKeychainPromptPreference.securityFrameworkFallbackMode()
            let fallbackDecision = self.securityFrameworkFallbackPromptDecision(
                promptMode: fallbackPromptMode,
                allowKeychainPrompt: true,
                respectKeychainPromptCooldown: false)
            self.log.debug(
                "Claude keychain Security.framework fallback prompt policy evaluated",
                metadata: [
                    "reader": "securityFrameworkFallback",
                    "fallbackPromptMode": fallbackPromptMode.rawValue,
                    "fallbackPromptAllowed": "\(fallbackDecision.allowed)",
                    "fallbackBlockedReason": fallbackDecision.blockedReason ?? "none",
                ])
            guard fallbackDecision.allowed else {
                throw ClaudeOAuthCredentialsError.notFound
            }
            return try self.loadFromClaudeKeychainUsingSecurityFramework(
                promptMode: fallbackPromptMode,
                allowKeychainPrompt: true)
        }
        return try self.loadFromClaudeKeychainUsingSecurityFramework()
    }

    /// Legacy alias for backward compatibility
    public static func loadFromKeychain() throws -> Data {
        try self.loadFromClaudeKeychain()
    }

    private static func loadFromClaudeKeychainUsingSecurityFramework(
        promptMode: ClaudeOAuthKeychainPromptMode = ClaudeOAuthKeychainPromptPreference.current(),
        allowKeychainPrompt: Bool = true) throws -> Data
    {
        #if DEBUG
        if let store = taskClaudeKeychainOverrideStore, let override = store.data {
            return override
        }
        if let override = taskClaudeKeychainDataOverride {
            return override
        }
        #endif
        #if os(macOS)
        let candidates = self.claudeKeychainCandidatesWithoutPrompt(promptMode: promptMode)
        if let newest = candidates.first {
            do {
                if let data = try self.loadClaudeKeychainData(
                    candidate: newest,
                    allowKeychainPrompt: allowKeychainPrompt,
                    promptMode: promptMode),
                    !data.isEmpty
                {
                    // Store fingerprint after a successful interactive read so we don't immediately try to
                    // "sync" in the background (which can still show UI on some systems).
                    let modifiedAt = newest.modifiedAt.map { Int($0.timeIntervalSince1970) }
                    let createdAt = newest.createdAt.map { Int($0.timeIntervalSince1970) }
                    let persistentRefHash = Self.sha256Prefix(newest.persistentRef)
                    self.saveClaudeKeychainFingerprint(
                        ClaudeKeychainFingerprint(
                            modifiedAt: modifiedAt,
                            createdAt: createdAt,
                            persistentRefHash: persistentRefHash))
                    return data
                }
            } catch let error as ClaudeOAuthCredentialsError {
                if case .keychainError = error {
                    ClaudeOAuthKeychainAccessGate.recordDenied()
                }
                throw error
            }
        }

        // Fallback: legacy query (may pick an arbitrary duplicate).
        do {
            if let data = try self.loadClaudeKeychainLegacyData(
                allowKeychainPrompt: allowKeychainPrompt,
                promptMode: promptMode),
                !data.isEmpty
            {
                // Same as above: store fingerprint after interactive read to avoid background "sync" reads.
                self.saveClaudeKeychainFingerprint(self.currentClaudeKeychainFingerprintWithoutPrompt())
                return data
            }
        } catch let error as ClaudeOAuthCredentialsError {
            if case .keychainError = error {
                ClaudeOAuthKeychainAccessGate.recordDenied()
            }
            throw error
        }
        throw ClaudeOAuthCredentialsError.notFound
        #else
        throw ClaudeOAuthCredentialsError.notFound
        #endif
    }

    #if os(macOS)
    private struct ClaudeKeychainCandidate {
        let persistentRef: Data
        let account: String?
        let modifiedAt: Date?
        let createdAt: Date?
    }

    private static func claudeKeychainCandidatesProbeWithoutPrompt(
        promptMode: ClaudeOAuthKeychainPromptMode = ClaudeOAuthKeychainPromptPreference
            .current(),
        enforcePromptPolicy: Bool = true) -> ClaudeKeychainProbe<[ClaudeKeychainCandidate]>
    {
        if enforcePromptPolicy {
            guard self.shouldAllowClaudeCodeKeychainAccess(mode: promptMode, allowKeychainPrompt: false)
            else { return .unavailable }
            if self.isPromptPolicyApplicable,
               ProviderInteractionContext.current == .background,
               !ClaudeOAuthKeychainAccessGate.shouldAllowPrompt()
            {
                return .unavailable
            }
        } else {
            guard self.keychainAccessAllowed else { return .unavailable }
        }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.claudeKeychainService,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnPersistentRef as String: true,
        ]
        KeychainNoUIQuery.apply(to: &query)

        let (status, result, durationMs) = ClaudeOAuthKeychainQueryTiming.copyMatching(query)
        if ClaudeOAuthKeychainQueryTiming
            .backoffIfSlowNoUIQuery(durationMs, self.claudeKeychainService, self.log)
        {
            return .unavailable
        }
        if status == errSecUserCanceled || status == errSecAuthFailed || status == errSecNoAccessForItem {
            ClaudeOAuthKeychainAccessGate.recordDenied()
        }
        if status == errSecItemNotFound {
            return .value([])
        }
        guard status == errSecSuccess else { return .unavailable }
        guard let rows = result as? [[String: Any]], !rows.isEmpty else { return .value([]) }

        let candidates: [ClaudeKeychainCandidate] = rows.compactMap { row in
            guard let persistentRef = row[kSecValuePersistentRef as String] as? Data else { return nil }
            return ClaudeKeychainCandidate(
                persistentRef: persistentRef,
                account: row[kSecAttrAccount as String] as? String,
                modifiedAt: row[kSecAttrModificationDate as String] as? Date,
                createdAt: row[kSecAttrCreationDate as String] as? Date)
        }

        let sorted = candidates.sorted { lhs, rhs in
            let lhsDate = lhs.modifiedAt ?? lhs.createdAt ?? Date.distantPast
            let rhsDate = rhs.modifiedAt ?? rhs.createdAt ?? Date.distantPast
            return lhsDate > rhsDate
        }
        return .value(sorted)
    }

    private static func claudeKeychainCandidatesWithoutPrompt(
        promptMode: ClaudeOAuthKeychainPromptMode = ClaudeOAuthKeychainPromptPreference
            .current()) -> [ClaudeKeychainCandidate]
    {
        switch self.claudeKeychainCandidatesProbeWithoutPrompt(promptMode: promptMode) {
        case .unavailable:
            []
        case let .value(candidates):
            candidates
        }
    }

    private static func claudeKeychainLegacyCandidateProbeWithoutPrompt(
        promptMode: ClaudeOAuthKeychainPromptMode = ClaudeOAuthKeychainPromptPreference
            .current(),
        enforcePromptPolicy: Bool = true) -> ClaudeKeychainProbe<ClaudeKeychainCandidate?>
    {
        if enforcePromptPolicy {
            guard self.shouldAllowClaudeCodeKeychainAccess(mode: promptMode, allowKeychainPrompt: false)
            else { return .unavailable }
            if self.isPromptPolicyApplicable,
               ProviderInteractionContext.current == .background,
               !ClaudeOAuthKeychainAccessGate.shouldAllowPrompt()
            {
                return .unavailable
            }
        } else {
            guard self.keychainAccessAllowed else { return .unavailable }
        }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.claudeKeychainService,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
            kSecReturnPersistentRef as String: true,
        ]
        KeychainNoUIQuery.apply(to: &query)

        let (status, result, durationMs) = ClaudeOAuthKeychainQueryTiming.copyMatching(query)
        if ClaudeOAuthKeychainQueryTiming
            .backoffIfSlowNoUIQuery(durationMs, self.claudeKeychainService, self.log)
        {
            return .unavailable
        }
        if status == errSecUserCanceled || status == errSecAuthFailed || status == errSecNoAccessForItem {
            ClaudeOAuthKeychainAccessGate.recordDenied()
        }
        if status == errSecItemNotFound {
            return .value(nil)
        }
        guard status == errSecSuccess else { return .unavailable }
        guard let row = result as? [String: Any] else { return .value(nil) }
        guard let persistentRef = row[kSecValuePersistentRef as String] as? Data else { return .value(nil) }
        return .value(ClaudeKeychainCandidate(
            persistentRef: persistentRef,
            account: row[kSecAttrAccount as String] as? String,
            modifiedAt: row[kSecAttrModificationDate as String] as? Date,
            createdAt: row[kSecAttrCreationDate as String] as? Date))
    }

    private static func claudeKeychainLegacyCandidateWithoutPrompt(
        promptMode: ClaudeOAuthKeychainPromptMode = ClaudeOAuthKeychainPromptPreference
            .current()) -> ClaudeKeychainCandidate?
    {
        switch self.claudeKeychainLegacyCandidateProbeWithoutPrompt(promptMode: promptMode) {
        case .unavailable:
            nil
        case let .value(candidate):
            candidate
        }
    }

    private static func loadClaudeKeychainData(
        candidate: ClaudeKeychainCandidate,
        allowKeychainPrompt: Bool,
        promptMode: ClaudeOAuthKeychainPromptMode = ClaudeOAuthKeychainPromptPreference.current()) throws -> Data?
    {
        guard self.shouldAllowClaudeCodeKeychainAccess(mode: promptMode, allowKeychainPrompt: allowKeychainPrompt)
        else { return nil }
        self.log.debug(
            "Claude keychain data read start",
            metadata: [
                "service": self.claudeKeychainService,
                "interactive": "\(allowKeychainPrompt)",
                "process": ProcessInfo.processInfo.processName,
            ])

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecValuePersistentRef as String: candidate.persistentRef,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]

        if !allowKeychainPrompt {
            KeychainNoUIQuery.apply(to: &query)
        }

        var result: AnyObject?
        let startedAtNs = DispatchTime.now().uptimeNanoseconds
        let status = KeychainSecurity.copyMatching(query as CFDictionary, &result)
        let durationMs = Double(DispatchTime.now().uptimeNanoseconds - startedAtNs) / 1_000_000.0
        self.log.debug(
            "Claude keychain data read result",
            metadata: [
                "service": self.claudeKeychainService,
                "interactive": "\(allowKeychainPrompt)",
                "status": "\(status)",
                "duration_ms": String(format: "%.2f", durationMs),
                "process": ProcessInfo.processInfo.processName,
            ])
        switch status {
        case errSecSuccess:
            if let data = result as? Data {
                return data
            }
            return nil
        case errSecItemNotFound:
            return nil
        case errSecInteractionNotAllowed:
            if allowKeychainPrompt {
                ClaudeOAuthKeychainAccessGate.recordDenied()
                throw ClaudeOAuthCredentialsError.keychainError(Int(status))
            }
            return nil
        case errSecUserCanceled, errSecAuthFailed:
            ClaudeOAuthKeychainAccessGate.recordDenied()
            throw ClaudeOAuthCredentialsError.keychainError(Int(status))
        case errSecNoAccessForItem:
            ClaudeOAuthKeychainAccessGate.recordDenied()
            throw ClaudeOAuthCredentialsError.keychainError(Int(status))
        default:
            throw ClaudeOAuthCredentialsError.keychainError(Int(status))
        }
    }

    private static func loadClaudeKeychainLegacyData(
        allowKeychainPrompt: Bool,
        promptMode: ClaudeOAuthKeychainPromptMode = ClaudeOAuthKeychainPromptPreference.current()) throws -> Data?
    {
        guard self.shouldAllowClaudeCodeKeychainAccess(mode: promptMode, allowKeychainPrompt: allowKeychainPrompt)
        else { return nil }
        self.log.debug(
            "Claude keychain legacy data read start",
            metadata: [
                "service": self.claudeKeychainService,
                "interactive": "\(allowKeychainPrompt)",
                "process": ProcessInfo.processInfo.processName,
            ])

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.claudeKeychainService,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]

        if !allowKeychainPrompt {
            KeychainNoUIQuery.apply(to: &query)
        }

        var result: AnyObject?
        let startedAtNs = DispatchTime.now().uptimeNanoseconds
        let status = KeychainSecurity.copyMatching(query as CFDictionary, &result)
        let durationMs = Double(DispatchTime.now().uptimeNanoseconds - startedAtNs) / 1_000_000.0
        self.log.debug(
            "Claude keychain legacy data read result",
            metadata: [
                "service": self.claudeKeychainService,
                "interactive": "\(allowKeychainPrompt)",
                "status": "\(status)",
                "duration_ms": String(format: "%.2f", durationMs),
                "process": ProcessInfo.processInfo.processName,
            ])
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        case errSecInteractionNotAllowed:
            if allowKeychainPrompt {
                ClaudeOAuthKeychainAccessGate.recordDenied()
                throw ClaudeOAuthCredentialsError.keychainError(Int(status))
            }
            return nil
        case errSecUserCanceled, errSecAuthFailed:
            ClaudeOAuthKeychainAccessGate.recordDenied()
            throw ClaudeOAuthCredentialsError.keychainError(Int(status))
        case errSecNoAccessForItem:
            ClaudeOAuthKeychainAccessGate.recordDenied()
            throw ClaudeOAuthCredentialsError.keychainError(Int(status))
        default:
            throw ClaudeOAuthCredentialsError.keychainError(Int(status))
        }
    }
    #endif

    private static func loadFromEnvironment(_ environment: [String: String])
        -> ClaudeOAuthCredentials?
    {
        guard
            let token = environment[self.environmentTokenKey]?.trimmingCharacters(
                in: .whitespacesAndNewlines),
            !token.isEmpty
        else {
            return nil
        }

        let scopes: [String] = {
            guard let raw = environment[self.environmentScopesKey] else { return ["user:profile"] }
            let parsed =
                raw
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            return parsed.isEmpty ? ["user:profile"] : parsed
        }()

        return ClaudeOAuthCredentials(
            accessToken: token,
            refreshToken: nil,
            expiresAt: Date.distantFuture,
            scopes: scopes,
            rateLimitTier: nil)
    }

    #if DEBUG
    public static func withCredentialsURLOverrideForTesting<T>(_ url: URL?, operation: () throws -> T) rethrows -> T {
        try self.$taskCredentialsURLOverride.withValue(url) {
            try operation()
        }
    }

    public static func withCredentialsURLOverrideForTesting<T>(_ url: URL?, operation: () async throws -> T)
    async rethrows -> T {
        try await self.$taskCredentialsURLOverride.withValue(url) {
            try await operation()
        }
    }

    public static var currentCredentialsURLOverrideForTesting: URL? {
        self.taskCredentialsURLOverride
    }

    static func withCredentialsProfileIdentifierOverrideForTesting<T>(
        _ profileIdentifier: String?,
        operation: () throws -> T) rethrows -> T
    {
        try self.$taskCredentialsProfileIdentifierOverride.withValue(profileIdentifier) {
            try operation()
        }
    }

    static var resolvedCredentialsURLForTesting: URL {
        self.credentialsFileURL(environment: ProcessInfo.processInfo.environment)
    }
    #endif

    private static func saveToCacheKeychain(
        _ data: Data,
        owner: ClaudeOAuthCredentialOwner? = nil,
        historyOwnerIdentifier: String? = nil,
        profileIdentifier: String)
    {
        guard self.shouldUseCodexBarOAuthKeychainCache else {
            self.markPendingCodexBarOAuthKeychainCacheClear(profileIdentifier: profileIdentifier)
            return
        }
        let entry = CacheEntry(
            data: data,
            storedAt: Date(),
            owner: owner,
            historyOwnerIdentifier: historyOwnerIdentifier,
            profileIdentifier: profileIdentifier)
        self.currentPendingCodexBarOAuthKeychainCacheClearStore.withCacheTransaction(
            profileIdentifier: profileIdentifier,
            includingLegacyState: { profilePending, legacyCleanupPending, _ in
                if profilePending {
                    if self.clearProfileCacheKeychain(profileIdentifier: profileIdentifier) {
                        profilePending = false
                    } else {
                        return
                    }
                }
                if legacyCleanupPending {
                    legacyCleanupPending = !self.clearLegacyCacheKeychain()
                }
                profilePending = !KeychainCacheStore.storeResult(
                    key: self.cacheKey(profileIdentifier: profileIdentifier),
                    entry: entry)
            })
    }

    @discardableResult
    private static func clearCacheKeychain(profileIdentifier: String) -> Bool {
        if self.shouldUseCodexBarOAuthKeychainCache {
            var profileCleared = false
            self.currentPendingCodexBarOAuthKeychainCacheClearStore.withCacheTransaction(
                profileIdentifier: profileIdentifier,
                includingLegacyState: { profilePending, legacyCleanupPending, legacyRecheckPending in
                    switch KeychainCacheStore.clearResult(key: self.cacheKey(profileIdentifier: profileIdentifier)) {
                    case .removed, .missing:
                        profilePending = false
                        profileCleared = true
                    case .failed:
                        profilePending = true
                        profileCleared = false
                    }
                    if legacyCleanupPending {
                        legacyCleanupPending = !self.clearLegacyCacheKeychain()
                    }
                    // Invalidation must retire an attributable entry from the released one-key layout before
                    // a later load can migrate it back. A failed delete leaves a distinct cleanup tombstone.
                    if !legacyCleanupPending {
                        switch KeychainCacheStore.load(key: self.legacyCacheKey, as: CacheEntry.self) {
                        case let .found(entry)
                            where self.legacyCacheEntry(entry, isAttributableTo: profileIdentifier):
                            legacyRecheckPending = false
                            legacyCleanupPending = !self.clearLegacyCacheKeychain()
                        case .invalid:
                            legacyRecheckPending = false
                            legacyCleanupPending = !self.clearLegacyCacheKeychain()
                        case .found, .missing:
                            legacyRecheckPending = false
                        case .temporarilyUnavailable:
                            legacyRecheckPending = true
                        }
                        if legacyCleanupPending {
                            legacyRecheckPending = false
                        }
                    }
                })
            return profileCleared
        } else {
            self.markPendingCodexBarOAuthKeychainCacheClear(profileIdentifier: profileIdentifier)
            return false
        }
    }

    private static func loadCodexBarOAuthKeychainCache(
        profileIdentifier: String) -> KeychainCacheStore.LoadResult<CacheEntry>
    {
        guard self.shouldUseCodexBarOAuthKeychainCache else { return .missing }
        var result: KeychainCacheStore.LoadResult<CacheEntry> = .temporarilyUnavailable
        self.currentPendingCodexBarOAuthKeychainCacheClearStore.withCacheTransaction(
            profileIdentifier: profileIdentifier,
            includingLegacyState: { profilePending, legacyCleanupPending, legacyRecheckPending in
                if profilePending {
                    if self.clearProfileCacheKeychain(profileIdentifier: profileIdentifier) {
                        profilePending = false
                    } else {
                        return
                    }
                }
                if legacyCleanupPending {
                    legacyCleanupPending = !self.clearLegacyCacheKeychain()
                }

                let profileCacheKey = self.cacheKey(profileIdentifier: profileIdentifier)
                let loaded = KeychainCacheStore.load(key: profileCacheKey, as: CacheEntry.self)
                switch loaded {
                case let .found(entry) where self.cacheEntrySurvivesDirectKeychainReadConsentRevocation(entry):
                    break
                case .found:
                    profilePending = !self.clearProfileCacheKeychain(profileIdentifier: profileIdentifier)
                    result = .missing
                    return
                case .missing:
                    break
                case .invalid, .temporarilyUnavailable:
                    result = loaded
                    return
                }
                if legacyRecheckPending {
                    switch KeychainCacheStore.load(key: self.legacyCacheKey, as: CacheEntry.self) {
                    case let .found(entry)
                        where self.legacyCacheEntry(entry, isAttributableTo: profileIdentifier):
                        legacyRecheckPending = false
                        legacyCleanupPending = !self.clearLegacyCacheKeychain()
                        result = loaded
                        return
                    case .invalid:
                        legacyRecheckPending = false
                        legacyCleanupPending = !self.clearLegacyCacheKeychain()
                        result = loaded
                        return
                    case .found, .missing:
                        legacyRecheckPending = false
                        result = loaded
                        return
                    case .temporarilyUnavailable:
                        result = if case .found = loaded {
                            loaded
                        } else {
                            .temporarilyUnavailable
                        }
                        return
                    }
                }
                if case .found = loaded {
                    result = loaded
                    return
                }
                // A failed legacy delete is a durable tombstone for this profile. Safe sources may repopulate
                // the profile cache, but the stale one-key entry is never eligible for migration while pending.
                guard !legacyCleanupPending else {
                    result = .missing
                    return
                }

                let legacyLoaded = KeychainCacheStore.load(key: self.legacyCacheKey, as: CacheEntry.self)
                guard case let .found(entry) = legacyLoaded else {
                    result = legacyLoaded
                    return
                }
                guard self.cacheEntrySurvivesDirectKeychainReadConsentRevocation(entry) else {
                    legacyCleanupPending = !self.clearLegacyCacheKeychain()
                    result = .missing
                    return
                }
                if self.legacyCacheEntry(entry, isAttributableTo: profileIdentifier) {
                    let migrated = CacheEntry(
                        data: entry.data,
                        storedAt: entry.storedAt,
                        owner: entry.owner,
                        historyOwnerIdentifier: entry.historyOwnerIdentifier,
                        profileIdentifier: profileIdentifier,
                        directKeychainReadConsentRevocationMarker: entry.directKeychainReadConsentRevocationMarker)
                    guard KeychainCacheStore.storeResult(key: profileCacheKey, entry: migrated) else {
                        self.log.warning("Claude OAuth legacy cache profile migration could not be persisted")
                        result = .temporarilyUnavailable
                        return
                    }
                    legacyCleanupPending = !self.clearLegacyCacheKeychain()
                    result = .found(migrated)
                    return
                }
                result = .missing
            })
        return result
    }

    private static func cacheEntrySurvivesDirectKeychainReadConsentRevocation(_ entry: CacheEntry) -> Bool {
        guard entry.owner == nil || entry.owner == .claudeCLI else { return true }
        guard let marker = self.currentDirectKeychainReadConsentRevocationMarker else { return true }
        return entry.directKeychainReadConsentRevocationMarker == marker
    }

    private static var currentDirectKeychainReadConsentRevocationMarker: String? {
        #if DEBUG
        if let store = self.taskDirectKeychainReadConsentRevocationMarkerStoreOverride {
            return store.marker
        }
        if KeychainTestSafety.shouldIsolateUserStateUnderTests() {
            return nil
        }
        #endif
        self.sharedDefaults.synchronize()
        return self.sharedDefaults.string(forKey: self.directKeychainReadConsentRevocationMarkerKey)
    }

    private static func advanceDirectKeychainReadConsentRevocationMarker() {
        #if DEBUG
        if let store = self.taskDirectKeychainReadConsentRevocationMarkerStoreOverride {
            store.advance()
            return
        }
        #endif
        self.sharedDefaults.set(UUID().uuidString, forKey: self.directKeychainReadConsentRevocationMarkerKey)
        self.sharedDefaults.synchronize()
    }

    private static func cacheKey(profileIdentifier: String) -> KeychainCacheStore.Key {
        KeychainCacheStore.Key(
            category: self.legacyCacheKey.category,
            identifier: self.profileCacheKeyPrefix + profileIdentifier)
    }

    private static func clearProfileCacheKeychain(profileIdentifier: String) -> Bool {
        guard self.shouldUseCodexBarOAuthKeychainCache else { return false }
        return switch KeychainCacheStore.clearResult(key: self.cacheKey(profileIdentifier: profileIdentifier)) {
        case .removed, .missing:
            true
        case .failed:
            false
        }
    }

    private static func clearLegacyCacheKeychain() -> Bool {
        switch KeychainCacheStore.clearResult(key: self.legacyCacheKey) {
        case .removed, .missing:
            true
        case .failed:
            false
        }
    }

    private static func legacyCacheEntry(
        _ entry: CacheEntry,
        isAttributableTo profileIdentifier: String) -> Bool
    {
        entry.profileIdentifier == profileIdentifier ||
            entry.profileIdentifier == nil &&
            profileIdentifier == self.historicalDefaultCredentialsProfileIdentifier
    }

    #if DEBUG
    static func cacheKeyForTesting(profileIdentifier: String) -> KeychainCacheStore.Key {
        self.cacheKey(profileIdentifier: profileIdentifier)
    }
    #endif

    private static var historicalDefaultCredentialsFilePath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent(".credentials.json")
            .standardizedFileURL.path
    }

    static var historicalDefaultCredentialsProfileIdentifier: String {
        self.credentialsProfileIdentifier(for: URL(fileURLWithPath: self.historicalDefaultCredentialsFilePath))
    }

    private static var shouldUseCodexBarOAuthKeychainCache: Bool {
        ClaudeOAuthKeychainPromptPreference.storedMode() != .never
    }

    private static func markPendingCodexBarOAuthKeychainCacheClear(profileIdentifier: String) {
        self.currentPendingCodexBarOAuthKeychainCacheClearStore.withCacheTransaction(
            profileIdentifier: profileIdentifier,
            includingLegacyState: { profilePending, _, legacyRecheckPending in
                profilePending = true
                // Cache I/O is unavailable here, so legacy ownership cannot be classified. Persist a conditional
                // recheck: the historical default can retire its old entry without deleting a custom sibling.
                legacyRecheckPending = true
            })
    }

    private static func hasPendingCodexBarOAuthKeychainCacheClear(profileIdentifier: String) -> Bool {
        self.currentPendingCodexBarOAuthKeychainCacheClearStore.isPending(profileIdentifier: profileIdentifier)
    }

    #if DEBUG
    static var hasPendingCodexBarOAuthKeychainCacheClearForTesting: Bool {
        self.currentPendingCodexBarOAuthKeychainCacheClearStore.isPending
    }
    #endif

    private static var currentPendingCodexBarOAuthKeychainCacheClearStore: ClaudeOAuthPendingCacheClearStore {
        #if DEBUG
        if let store = self.taskPendingCacheClearStoreOverride {
            return store
        }
        // Under tests without a TaskLocal store, use an ephemeral sink so concurrent tests never
        // share pending state or write the process-shared app tombstone suite. Coherent pending
        // semantics require withPendingCacheClearStoreOverrideForTesting / isolated memory cache.
        if KeychainTestSafety.shouldIsolateUserStateUnderTests() {
            return PendingCacheClearMemoryStore()
        }
        if let store = self.taskImplicitPendingCacheClearStoreOverride {
            return store
        }
        #endif
        return self.pendingCodexBarOAuthKeychainCacheClearStore
    }

    static var keychainAccessAllowed: Bool {
        #if DEBUG
        if let override = self.taskKeychainAccessOverride {
            return !override
        }
        if KeychainAccessGate.currentOverrideForTesting == true {
            return false
        }
        if let consentOverride = ClaudeOAuthDirectKeychainReadConsent.taskOverrideForTesting {
            return consentOverride
        }
        if self.hasTaskKeychainTestingOverride {
            return true
        }
        #endif
        // Claude Code owns `Claude Code-credentials` and rewrites the item during token refreshes. That rewrite
        // replaces its ACL, so any permission granted to CodexBar is inherently temporary and can cause recurring
        // macOS password dialogs. Production CodexBar therefore reads the foreign item only after the user
        // explicitly opted in (#2634); without consent every direct-read path stays closed, including the
        // freshness sync and delegated-refresh verification that route through this same gate.
        guard !KeychainAccessGate.isDisabled else { return false }
        return ClaudeOAuthDirectKeychainReadConsent.isGranted()
    }

    #if DEBUG
    private static var hasTaskKeychainTestingOverride: Bool {
        self.taskClaudeKeychainOverrideStore != nil
            || self.taskClaudeKeychainDataOverride != nil
            || self.taskClaudeKeychainFingerprintOverride != nil
            || self.taskInteractiveClaudeKeychainReadOverride != nil
            || self.taskSecurityCLIReadOverride != nil
            || self.taskSecurityCLIReadAccountOverride != nil
    }
    #endif

    private static var isPromptPolicyApplicable: Bool {
        ClaudeOAuthKeychainPromptPreference.isApplicable()
    }

    private static func securityFrameworkFallbackPromptDecision(
        promptMode: ClaudeOAuthKeychainPromptMode,
        allowKeychainPrompt: Bool,
        respectKeychainPromptCooldown: Bool) -> (allowed: Bool, blockedReason: String?)
    {
        guard allowKeychainPrompt else {
            return (allowed: false, blockedReason: "allowKeychainPromptFalse")
        }
        guard self.shouldAllowClaudeCodeKeychainAccess(mode: promptMode) else {
            return (allowed: false, blockedReason: self.fallbackBlockedReason(promptMode: promptMode))
        }
        if respectKeychainPromptCooldown,
           !ClaudeOAuthKeychainAccessGate.shouldAllowPrompt()
        {
            return (allowed: false, blockedReason: "cooldown")
        }
        return (allowed: true, blockedReason: nil)
    }

    private static func fallbackBlockedReason(promptMode: ClaudeOAuthKeychainPromptMode) -> String {
        if !self.keychainAccessAllowed {
            return "keychainDisabled"
        }
        switch promptMode {
        case .never:
            return "never"
        case .onlyOnUserAction:
            return "onlyOnUserAction-background"
        case .always:
            return "disallowed"
        }
    }

    private static func shouldAllowClaudeCodeKeychainAccess(
        mode: ClaudeOAuthKeychainPromptMode = ClaudeOAuthKeychainPromptPreference.current(),
        allowKeychainPrompt: Bool = true) -> Bool
    {
        guard self.keychainAccessAllowed else { return false }
        switch mode {
        case .never:
            return false
        case .onlyOnUserAction:
            return ProviderInteractionContext.current == .userInitiated
        case .always: return true
        }
    }

    static func preferredClaudeKeychainAccountForSecurityCLIRead(
        interaction: ProviderInteraction = ProviderInteractionContext.current) -> String?
    {
        // Keep the experimental background path fully on /usr/bin/security by default.
        // Account pinning requires Security.framework candidate probing, so only allow it on explicit user actions.
        guard interaction == .userInitiated else { return nil }
        #if DEBUG
        if let override = self.taskSecurityCLIReadAccountOverride {
            return override
        }
        #endif
        #if os(macOS)
        let mode = ClaudeOAuthKeychainPromptPreference.current()
        guard self.shouldAllowClaudeCodeKeychainAccess(mode: mode, allowKeychainPrompt: false) else { return nil }
        // Keep experimental mode prompt-safe: avoid Security.framework candidate probes when preflight says
        // interaction is likely.
        if self.shouldShowClaudeKeychainPreAlert() {
            return nil
        }
        guard let account = self.claudeKeychainCandidatesWithoutPrompt(promptMode: mode).first?.account,
              !account.isEmpty
        else {
            return nil
        }
        return account
        #else
        return nil
        #endif
    }

    private static func credentialsFileURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL
    {
        #if DEBUG
        if let override = self.taskCredentialsURLOverride {
            return override
        }
        if KeychainTestSafety.shouldIsolateUserStateUnderTests(),
           !self.taskUseEnvironmentCredentialsURLForTesting
        {
            return self.isolatedTestCredentialsURL
        }
        #endif
        return ClaudeConfigPaths.credentialsURL(environment: environment)
    }

    public static func credentialsProfileIdentifier(environment: [String: String]) -> String {
        #if DEBUG
        if let override = self.taskCredentialsProfileIdentifierOverride {
            return override
        }
        #endif
        return self.credentialsProfileIdentifier(for: self.credentialsFileURL(environment: environment))
    }

    private static func credentialsProfileIdentifier(for credentialsURL: URL) -> String {
        let path = credentialsURL.standardizedFileURL.path
        let material = Data("codexbar:claude-oauth-cache-profile:v1\0\(path)".utf8)
        return self.sha256Hex(material)
    }

    private static func fileFingerprintKey(profileIdentifier: String) -> String {
        self.legacyFileFingerprintKey + self.fileFingerprintProfileSeparator + profileIdentifier
    }

    private static func credentialsFileQuarantineKey(profileIdentifier: String) -> String {
        self.credentialsFileQuarantineKeyPrefix + profileIdentifier
    }

    private static func loadQuarantinedCredentialsFileFingerprint(
        profileIdentifier: String) -> CredentialsFileFingerprint?
    {
        #if DEBUG
        if let store = self.taskCredentialsFileFingerprintStoreOverride {
            return store.loadQuarantine(profileIdentifier: profileIdentifier)
        }
        #endif
        guard let data = UserDefaults.standard.data(
            forKey: self.credentialsFileQuarantineKey(profileIdentifier: profileIdentifier))
        else { return nil }
        return try? JSONDecoder().decode(CredentialsFileFingerprint.self, from: data)
    }

    private static func saveQuarantinedCredentialsFileFingerprint(
        _ fingerprint: CredentialsFileFingerprint?,
        profileIdentifier: String)
    {
        #if DEBUG
        if let store = self.taskCredentialsFileFingerprintStoreOverride {
            store.saveQuarantine(fingerprint, profileIdentifier: profileIdentifier)
            return
        }
        #endif
        let key = self.credentialsFileQuarantineKey(profileIdentifier: profileIdentifier)
        guard let fingerprint, let data = try? JSONEncoder().encode(fingerprint) else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        UserDefaults.standard.set(data, forKey: key)
    }

    private static func loadFileFingerprint(profileIdentifier: String) -> CredentialsFileFingerprint? {
        #if DEBUG
        if let store = self.taskCredentialsFileFingerprintStoreOverride {
            return store.load(
                profileIdentifier: profileIdentifier,
                historicalProfileIdentifier: self.historicalDefaultCredentialsProfileIdentifier)
        }
        #endif
        let defaults = UserDefaults.standard
        let scopedKey = self.fileFingerprintKey(profileIdentifier: profileIdentifier)
        if let data = defaults.data(forKey: scopedKey) {
            if profileIdentifier == self.historicalDefaultCredentialsProfileIdentifier {
                defaults.removeObject(forKey: self.legacyFileFingerprintKey)
            }
            return try? JSONDecoder().decode(CredentialsFileFingerprint.self, from: data)
        }
        guard profileIdentifier == self.historicalDefaultCredentialsProfileIdentifier,
              let data = defaults.data(forKey: self.legacyFileFingerprintKey)
        else {
            return nil
        }
        guard let fingerprint = try? JSONDecoder().decode(CredentialsFileFingerprint.self, from: data) else {
            return nil
        }
        let migratedData = (try? JSONEncoder().encode(fingerprint)) ?? data
        defaults.set(migratedData, forKey: scopedKey)
        defaults.removeObject(forKey: self.legacyFileFingerprintKey)
        return fingerprint
    }

    private static func saveFileFingerprint(
        _ fingerprint: CredentialsFileFingerprint?,
        profileIdentifier: String)
    {
        #if DEBUG
        if let store = self.taskCredentialsFileFingerprintStoreOverride {
            store.save(
                fingerprint,
                profileIdentifier: profileIdentifier,
                historicalProfileIdentifier: self.historicalDefaultCredentialsProfileIdentifier)
            return
        }
        #endif
        let defaults = UserDefaults.standard
        let scopedKey = self.fileFingerprintKey(profileIdentifier: profileIdentifier)
        if profileIdentifier == self.historicalDefaultCredentialsProfileIdentifier {
            defaults.removeObject(forKey: self.legacyFileFingerprintKey)
        }
        guard let fingerprint else {
            defaults.removeObject(forKey: scopedKey)
            return
        }
        if let data = try? JSONEncoder().encode(fingerprint) {
            defaults.set(data, forKey: scopedKey)
        }
    }

    private static func currentFileFingerprint(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> CredentialsFileFingerprint?
    {
        let url = self.credentialsFileURL(environment: environment)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        let modifiedAtMs = (attrs[.modificationDate] as? Date).map { Int($0.timeIntervalSince1970 * 1000) }
        return CredentialsFileFingerprint(
            path: url.standardizedFileURL.path,
            modifiedAtMs: modifiedAtMs,
            size: size)
    }

    #if DEBUG
    static func _resetCredentialsFileTrackingForTesting() {
        if let store = self.taskCredentialsFileFingerprintStoreOverride {
            store.reset()
        } else {
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: self.legacyFileFingerprintKey)
            for key in defaults.dictionaryRepresentation().keys
                where key.hasPrefix(self.legacyFileFingerprintKey + self.fileFingerprintProfileSeparator)
            {
                defaults.removeObject(forKey: key)
            }
            for key in defaults.dictionaryRepresentation().keys
                where key.hasPrefix(self.credentialsFileQuarantineKeyPrefix)
            {
                defaults.removeObject(forKey: key)
            }
        }
        if self.taskPendingCacheClearStoreOverride != nil {
            self.currentPendingCodexBarOAuthKeychainCacheClearStore.withCacheTransaction { pending in
                pending = false
            }
        }
    }

    static func _resetClaudeKeychainChangeTrackingForTesting() {
        UserDefaults.standard.removeObject(forKey: self.claudeKeychainFingerprintKey)
        UserDefaults.standard.removeObject(forKey: self.claudeKeychainFingerprintLegacyKey)
        self.claudeKeychainChangeCheckLock.lock()
        self.lastClaudeKeychainChangeCheckAt = nil
        self.claudeKeychainChangeCheckLock.unlock()
    }

    static func _resetClaudeKeychainChangeThrottleForTesting() {
        self.claudeKeychainChangeCheckLock.lock()
        self.lastClaudeKeychainChangeCheckAt = nil
        self.claudeKeychainChangeCheckLock.unlock()
    }
    #endif
}

// swiftlint:enable type_body_length

extension ClaudeOAuthCredentialsStore {
    /// After delegated Claude CLI refresh, re-load the Claude keychain entry without prompting and sync it into
    /// CodexBar's caches. This is used to avoid triggering a second OS keychain dialog during the OAuth retry.
    @discardableResult
    static func syncFromClaudeKeychainWithoutPrompt(
        now: Date = Date(),
        environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool
    {
        let profileIdentifier = self.credentialsProfileIdentifier(environment: environment)
        return Recovery(
            context: self.currentCollaboratorContext(),
            profileIdentifier: profileIdentifier).syncFromClaudeKeychainWithoutPrompt(now: now)
    }

    private static func shouldShowClaudeKeychainPreAlert() -> Bool {
        #if DEBUG
        // Synthetic Claude Keychain fixtures must not fall through to the real preflight. Tests that explicitly
        // override the preflight still exercise its prompt-policy branches.
        if self.hasTaskKeychainTestingOverride,
           !KeychainAccessPreflight.hasCheckGenericPasswordOverrideForTesting
        {
            return false
        }
        #endif
        let mode = ClaudeOAuthKeychainPromptPreference.current()
        guard self.shouldAllowClaudeCodeKeychainAccess(mode: mode, allowKeychainPrompt: false) else { return false }
        return switch KeychainAccessPreflight.checkGenericPassword(service: self.claudeKeychainService, account: nil) {
        case .interactionRequired:
            true
        case .failure:
            // If preflight fails, we can't be sure whether interaction is required (or if the preflight itself
            // is impacted by a misbehaving Keychain configuration). Be conservative and show the pre-alert.
            true
        case .allowed, .notFound:
            false
        }
    }

    private static func shouldNotifyClaudeKeychainPreAlert() -> Bool {
        let mode = ClaudeOAuthKeychainPromptPreference.current()
        guard self.shouldAllowClaudeCodeKeychainAccess(mode: mode) else { return false }
        // Attribute-only preflight can report success even when reading the secret will prompt. Explicit user
        // actions are rare and intentional, so always explain the read before Security.framework can show UI.
        return ProviderInteractionContext.current == .userInitiated || self.shouldShowClaudeKeychainPreAlert()
    }

    /// Refresh the access token using a refresh token.
    /// Updates CodexBar's keychain cache with the new credentials.
    public static func refreshAccessToken(
        refreshToken: String,
        existingScopes: [String],
        existingRateLimitTier: String?,
        existingSubscriptionType: String? = nil) async throws -> ClaudeOAuthCredentials
    {
        let historyOwnerIdentifier = ClaudeOAuthCredentials.historyOwnerIdentifier(forRefreshToken: refreshToken)
        let environment = ProcessInfo.processInfo.environment
        return try await Refresher(
            context: self.currentCollaboratorContext(),
            profileIdentifier: self.credentialsProfileIdentifier(environment: environment),
            environment: environment).refreshAccessToken(
            refreshToken: refreshToken,
            existingScopes: existingScopes,
            existingRateLimitTier: existingRateLimitTier,
            existingSubscriptionType: existingSubscriptionType,
            historyOwnerIdentifier: historyOwnerIdentifier)
    }

    private enum RefreshFailureDisposition: String {
        case terminalInvalidGrant
        case transientBackoff
    }

    private static func extractOAuthErrorCode(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["error"] as? String
    }

    private static func refreshFailureDisposition(statusCode: Int, data: Data) -> RefreshFailureDisposition? {
        guard statusCode == 400 || statusCode == 401 else { return nil }
        if let error = self.extractOAuthErrorCode(from: data)?.lowercased(), error == "invalid_grant" {
            return .terminalInvalidGrant
        }
        return .transientBackoff
    }

    #if DEBUG
    static func extractOAuthErrorCodeForTesting(from data: Data) -> String? {
        self.extractOAuthErrorCode(from: data)
    }

    static func refreshFailureDispositionForTesting(statusCode: Int, data: Data) -> String? {
        self.refreshFailureDisposition(statusCode: statusCode, data: data)?.rawValue
    }
    #endif
}
