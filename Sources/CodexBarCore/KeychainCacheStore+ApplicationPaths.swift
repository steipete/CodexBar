import Foundation
#if os(macOS)
import Security
#endif

extension KeychainCacheStore {
    #if DEBUG
    @TaskLocal static var bundledAdHocProcessOverrideForTesting: Bool?
    #endif

    /// Ad-hoc app rebuilds cannot satisfy legacy Keychain ACLs created by an earlier executable identity.
    /// Keep cookie caches process-local for those builds; certificate-signed development and release apps
    /// retain the persistent Keychain cache.
    static var isBundledAdHocProcess: Bool {
        #if DEBUG
        if let override = self.bundledAdHocProcessOverrideForTesting {
            return override
        }
        #endif
        return self.detectedBundledAdHocProcess
    }

    private static let detectedBundledAdHocProcess: Bool = {
        #if os(macOS)
        guard let appBundle = Self.appBundleURL(containing: Bundle.main.bundleURL)
            ?? Bundle.main.executableURL.flatMap(Self.appBundleURL(containing:))
        else { return false }
        return !Self.hasCodeSigningCertificate(at: appBundle)
        #else
        return false
        #endif
    }()

    #if DEBUG
    static func withBundledAdHocProcessForTesting<T>(
        _ enabled: Bool,
        operation: () throws -> T) rethrows -> T
    {
        try self.$bundledAdHocProcessOverrideForTesting.withValue(enabled) {
            try operation()
        }
    }
    #endif

    static func trustedApplicationPathsForCacheAccess(
        bundleURL: URL = Bundle.main.bundleURL,
        executableURL: URL? = Bundle.main.executableURL,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [String]
    {
        var paths: [String] = []
        func append(_ path: String) {
            guard !path.isEmpty, fileExists(path), !paths.contains(path) else { return }
            paths.append(path)
        }

        // No .app ancestor means an ephemeral dev binary; trusting its bare path
        // would freeze a broken ACL onto the shared item (the packaged app would
        // then prompt on every read). Refuse the ACL entirely in that case —
        // unbundled processes use the in-memory store and never reach this path
        // in practice.
        guard let appBundle = self.appBundleURL(containing: bundleURL)
            ?? executableURL.flatMap(self.appBundleURL(containing:))
        else { return [] }
        append(appBundle.path)
        append(appBundle.appendingPathComponent("Contents/Helpers/CodexBarCLI").path)
        if let executableURL {
            append(executableURL.path)
        }
        return paths
    }

    /// The caller that will perform the secret-data operation after preflight. The cache ACL may trust
    /// multiple first-party executables, but one executable cannot authorize access on another's behalf.
    static func invokingApplicationPathsForCacheAccess(
        executableURL: URL? = Bundle.main.executableURL,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [String]
    {
        guard let path = executableURL?.path, !path.isEmpty, fileExists(path) else { return [] }
        return [path]
    }

    static func appBundleURL(containing url: URL) -> URL? {
        var current = url.standardizedFileURL
        while current.path != "/" {
            if current.pathExtension == "app" {
                return current
            }
            current.deleteLastPathComponent()
        }
        return nil
    }

    static func hasCodeSigningCertificate(at bundleURL: URL) -> Bool {
        #if os(macOS)
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode
        else { return false }

        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information) == errSecSuccess,
            let values = information as? [String: Any],
            let certificates = values[kSecCodeInfoCertificates as String] as? [SecCertificate]
        else { return false }
        return !certificates.isEmpty
        #else
        _ = bundleURL
        return false
        #endif
    }
}
