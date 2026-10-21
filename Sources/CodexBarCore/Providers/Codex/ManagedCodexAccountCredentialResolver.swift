import Foundation

/// A deliberately access-only view of a native Codex OAuth credential.
///
/// This type does not promise secure memory or zeroization. It prevents accidental serialization,
/// reflection, diagnostics, and equality-based handling of the bearer value at this boundary.
public struct ManagedCodexAccessCredential: Sendable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    private let accessToken: String
    public let expiresAt: Date

    init(accessToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
    }

    public var description: String {
        "ManagedCodexAccessCredential(redacted, expiresAt: \(self.expiresAt))"
    }

    public var debugDescription: String {
        self.description
    }

    public var customMirror: Mirror {
        Mirror(self, children: [(label: String?, value: Any)]())
    }

    /// Limit the bearer value's exposure to the immediate caller that must construct an authorized request.
    public func withAccessToken<Result>(_ body: (String) throws -> Result) rethrows -> Result {
        try body(self.accessToken)
    }
}

struct NativeCodexAccessSnapshot: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let accessToken: String
    let expiresAt: Date?
    let nativeDefaultAccountID: String?
    let nativeOwnerEmail: String?

    var description: String {
        "NativeCodexAccessSnapshot(redacted)"
    }

    var debugDescription: String {
        self.description
    }

    var customMirror: Mirror {
        Mirror(self, children: [(label: String?, value: Any)]())
    }

    static func read(home: URL) throws -> Self {
        guard let data = try DefaultCodexAuthMaterialReader().readAuthData(homeURL: home) else {
            throw CodexOAuthCredentialsError.notFound
        }
        let credentials = try CodexOAuthCredentialsStore.parse(data: data)
        guard !credentials.isAPIKey else { throw NativeCodexAccessSnapshotError.unsupportedCredential }
        // Promotion's native-default extraction excludes the usage reader's organizations-membership fallback.
        let account = try PreparedPromotionContextBuilder.runtimeAccount(from: data)
        let defaultAccountID: String? = if case let .providerAccount(id) = account.identity {
            id
        } else { nil }
        return Self(
            accessToken: credentials.accessToken,
            expiresAt: credentials.expiresAt,
            nativeDefaultAccountID: defaultAccountID,
            nativeOwnerEmail: CodexNativeCredentialOwnerIdentity.normalizedEmail(fromIDToken: credentials.idToken))
    }
}

private enum NativeCodexAccessSnapshotError: Error {
    case unsupportedCredential
}

public enum ManagedCodexCredentialRenewalReason: String, Equatable, Sendable {
    case expiryUnknown
    case expired
    case insufficientLifetime
}

public enum ManagedCodexCredentialTemporaryReason: String, Equatable, Sendable {
    case credentialUnavailable
    case credentialUnreadable
    case accountChanged
}

public enum ManagedCodexCredentialUnsupportedReason: String, Equatable, Sendable {
    case untrustedManagedHome
    case unsupportedCredentialSource
    case workspaceScope
    case bindingEvidenceInsufficient
    case invalidMinimumValidity
}

public enum ManagedCodexCredentialResolution: Sendable {
    case ready(ManagedCodexAccessCredential)
    case renewalRequired(ManagedCodexCredentialRenewalReason)
    case temporarilyUnavailable(ManagedCodexCredentialTemporaryReason)
    case accountNotFound
    case unsupported(ManagedCodexCredentialUnsupportedReason)
}

public struct ManagedCodexCredentialResolverPolicy: Sendable {
    /// A request larger than one day cannot be satisfied safely by this fresh-only resolver.
    public static let maximumMinimumValidity: TimeInterval = 24 * 60 * 60
    public let authorityMinimumValidity: TimeInterval
    public let clockSkew: TimeInterval

    public init(authorityMinimumValidity: TimeInterval = 60, clockSkew: TimeInterval = 30) {
        self.authorityMinimumValidity = authorityMinimumValidity
        self.clockSkew = clockSkew
    }
}

/// Read-only resolver for native OAuth credentials owned by a managed Codex home.
///
/// It never starts Codex, refreshes tokens, writes auth files, or retains a credential cache.
public struct ManagedCodexAccountCredentialResolver: Sendable {
    private let store: any ManagedCodexAccountMetadataLoading
    private let managedHomeRoot: URL
    private let policy: ManagedCodexCredentialResolverPolicy
    private let now: @Sendable () -> Date
    private let snapshotReader: @Sendable (URL) throws -> NativeCodexAccessSnapshot

    public init(
        store: any ManagedCodexAccountMetadataLoading,
        managedHomeRoot: URL,
        policy: ManagedCodexCredentialResolverPolicy = .init(),
        now: @escaping @Sendable () -> Date = Date.init)
    {
        self.init(
            store: store,
            managedHomeRoot: managedHomeRoot,
            policy: policy,
            now: now,
            snapshotReader: NativeCodexAccessSnapshot.read)
    }

    init(
        store: any ManagedCodexAccountMetadataLoading,
        managedHomeRoot: URL,
        policy: ManagedCodexCredentialResolverPolicy = .init(),
        now: @escaping @Sendable () -> Date = Date.init,
        snapshotReader: @escaping @Sendable (URL) throws -> NativeCodexAccessSnapshot)
    {
        self.store = store
        self.managedHomeRoot = managedHomeRoot
        self.policy = policy
        self.now = now
        self.snapshotReader = snapshotReader
    }

    public func resolve(accountID: UUID, minimumValidity: TimeInterval) -> ManagedCodexCredentialResolution {
        guard let requiredLifetime = self.requiredLifetime(minimumValidity) else {
            return .unsupported(.invalidMinimumValidity)
        }
        let first: ManagedCodexAccount
        do {
            guard let account = try self.store.loadAccountMetadata().account(id: accountID) else {
                return .accountNotFound
            }
            first = account
        } catch {
            return .temporarilyUnavailable(.credentialUnavailable)
        }
        guard let home = self.trustedHome(for: first) else {
            return .unsupported(.untrustedManagedHome)
        }
        let authFile = home.appendingPathComponent("auth.json", isDirectory: false)
        guard self.hasFileType(authFile, .typeRegular) else {
            return .temporarilyUnavailable(.credentialUnavailable)
        }

        let snapshot: NativeCodexAccessSnapshot
        do {
            snapshot = try self.snapshotReader(home)
        } catch is NativeCodexAccessSnapshotError {
            return .unsupported(.unsupportedCredentialSource)
        } catch {
            return .temporarilyUnavailable(.credentialUnreadable)
        }
        guard !snapshot.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .temporarilyUnavailable(.credentialUnreadable)
        }
        guard let owner = CodexIdentityResolver.normalizeEmail(first.email), owner == snapshot.nativeOwnerEmail else {
            return .unsupported(.bindingEvidenceInsufficient)
        }
        let nativeDefault = ManagedCodexAccount.normalizeWorkspaceAccountID(snapshot.nativeDefaultAccountID)
        guard nativeDefault != nil,
              first.effectiveWorkspaceAccountID == nil || first.effectiveWorkspaceAccountID == nativeDefault
        else {
            return first.effectiveWorkspaceAccountID == nil
                ? .unsupported(.bindingEvidenceInsufficient)
                : .unsupported(.workspaceScope)
        }

        do {
            guard let second = try self.store.loadAccountMetadata().account(id: accountID),
                  first.email == second.email,
                  first.effectiveWorkspaceAccountID == second.effectiveWorkspaceAccountID,
                  self.trustedHome(for: second) == home,
                  self.hasFileType(authFile, .typeRegular)
            else {
                return .temporarilyUnavailable(.accountChanged)
            }
        } catch {
            return .temporarilyUnavailable(.accountChanged)
        }
        guard let expiry = snapshot.expiresAt else {
            return .renewalRequired(.expiryUnknown)
        }
        let remaining = expiry.timeIntervalSince(self.now())
        if remaining <= 0 {
            return .renewalRequired(.expired)
        }
        guard remaining > requiredLifetime else {
            return .renewalRequired(.insufficientLifetime)
        }
        return .ready(ManagedCodexAccessCredential(accessToken: snapshot.accessToken, expiresAt: expiry))
    }

    private func requiredLifetime(_ callerMinimum: TimeInterval) -> TimeInterval? {
        let maximum = ManagedCodexCredentialResolverPolicy.maximumMinimumValidity
        guard callerMinimum.isFinite, (0...maximum).contains(callerMinimum),
              self.policy.authorityMinimumValidity.isFinite,
              (0...maximum).contains(self.policy.authorityMinimumValidity),
              self.policy.clockSkew.isFinite, self.policy.clockSkew >= 0
        else { return nil }
        let minimum = max(callerMinimum, self.policy.authorityMinimumValidity)
        guard minimum <= TimeInterval.greatestFiniteMagnitude - self.policy.clockSkew else { return nil }
        return minimum + self.policy.clockSkew
    }

    private func trustedHome(for account: ManagedCodexAccount) -> URL? {
        let root = self.managedHomeRoot.standardizedFileURL
        let home = URL(fileURLWithPath: account.managedHomePath, isDirectory: true).standardizedFileURL
        guard home.pathComponents.count > root.pathComponents.count,
              home.pathComponents.starts(with: root.pathComponents)
        else { return nil }
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let canonicalHome = home.resolvingSymlinksInPath().standardizedFileURL
        guard canonicalHome.pathComponents.count > canonicalRoot.pathComponents.count,
              canonicalHome.pathComponents.starts(with: canonicalRoot.pathComponents),
              self.hasFileType(canonicalRoot, .typeDirectory)
        else { return nil }
        var component = root
        for name in home.pathComponents.dropFirst(root.pathComponents.count) {
            component.appendPathComponent(name, isDirectory: true)
            guard self.hasFileType(component, .typeDirectory) else { return nil }
        }
        return canonicalHome
    }

    private func hasFileType(_ url: URL, _ type: FileAttributeType) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return false }
        return attributes[.type] as? FileAttributeType == type
    }
}
