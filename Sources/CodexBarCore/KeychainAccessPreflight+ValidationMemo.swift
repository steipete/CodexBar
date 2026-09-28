import Foundation

#if os(macOS)
import Security

extension KeychainAccessPreflight {
    final class ValidationMemo: @unchecked Sendable {
        static let capacity = 64
        static let rejectionLifetime: TimeInterval = 5 * 60

        /// Preflights are synchronous. Each pending key has its own result promise, so waiting callers
        /// share even a transient result without holding the dictionary lock or blocking unrelated keys.
        private final class Flight: @unchecked Sendable {
            private let completion = DispatchGroup()
            /// Written once before leave(), read only after a successful wait().
            private var result: OSStatus?

            init() { self.completion.enter() }

            func wait(timeout: DispatchTime = .distantFuture) -> OSStatus? {
                guard self.completion.wait(timeout: timeout) == .success else { return nil }
                return self.result
            }

            func complete(_ result: OSStatus?) {
                self.result = result
                self.completion.leave()
            }
        }

        // A timed-out native validation cannot be cancelled. Keep its slot occupied until it returns.
        private let validationSlots = DispatchSemaphore(value: 4)
        private let lock = NSLock()
        private var entries: [ValidationKey: (status: OSStatus, expiresAt: TimeInterval)] = [:]
        private var flights: [ValidationKey: Flight] = [:]
        private let onJoin: @Sendable () -> Void
        private let validationTimeout: TimeInterval

        init(validationTimeout: TimeInterval = 2, onJoin: @escaping @Sendable () -> Void = {}) {
            self.validationTimeout = validationTimeout
            self.onJoin = onJoin
        }

        private func performBoundedValidation(_ check: @escaping @Sendable () -> OSStatus?) -> OSStatus? {
            guard self.validationSlots.wait(timeout: .now()) == .success else { return nil }
            let result = Flight()
            DispatchQueue.global(qos: .utility).async {
                let value = check()
                self.validationSlots.signal()
                result.complete(value)
            }
            return result.wait(timeout: .now() + self.validationTimeout)
        }

        func validate(
            trustedApplication: Data?,
            path: String,
            now: TimeInterval = ProcessInfo.processInfo.systemUptime,
            check: @escaping @Sendable () -> OSStatus?) -> OSStatus?
        {
            guard let key = ValidationKey(trustedApplication: trustedApplication, path: path)
            else { return self.performBoundedValidation(check) }
            self.lock.lock()
            if let entry = self.entries[key], now < entry.expiresAt {
                self.lock.unlock()
                return entry.status
            }
            if let flight = self.flights[key] {
                self.lock.unlock()
                self.onJoin()
                return flight.wait()
            }
            let flight = Flight()
            self.flights[key] = flight
            self.lock.unlock()

            let result = self.performBoundedValidation(check)
            self.lock.withLock {
                self.entries = self.entries.filter { now < $0.value.expiresAt }
                // Executable and bundle metadata cannot prove that all sealed resources are unchanged.
                // Only confirmed rejections may outlive the validation currently in flight.
                if result == OSStatus(CSSMERR_CSP_VERIFY_FAILED), let result {
                    if self.entries.count >= Self.capacity,
                       let firstToExpire = self.entries.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key
                    {
                        self.entries.removeValue(forKey: firstToExpire)
                    }
                    self.entries[key] = (result, now + Self.rejectionLifetime)
                }
                flight.complete(result)
                self.flights.removeValue(forKey: key)
            }
            return result
        }
    }

    private struct ValidationKey: Hashable {
        let trustedApplication: Data
        let path: String
        let executable: FileIdentity
        let bundle: BundleIdentity?

        init?(trustedApplication: Data?, path: String) {
            guard let trustedApplication, let executable = FileIdentity(path: path) else { return nil }
            self.trustedApplication = trustedApplication
            self.path = path
            self.executable = executable
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            if let bundleURL = KeychainCacheStore.appBundleURL(containing: url) {
                guard let bundle = BundleIdentity(url: bundleURL) else { return nil }
                self.bundle = bundle
            } else {
                self.bundle = nil
            }
        }
    }

    private struct BundleIdentity: Hashable {
        let path: String
        let version: String
        let directory: FileIdentity
        let executablePath: String
        let executable: FileIdentity

        init?(url: URL) {
            // Bundle caches Info.plist values; read the file itself so an in-process update is visible.
            guard let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
                  let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let version = info["CFBundleVersion"] as? String,
                  let name = info["CFBundleExecutable"] as? String,
                  !name.isEmpty, !name.contains("/"), name != ".", name != "..",
                  let directory = FileIdentity(path: url.path)
            else { return nil }
            let executablePath = url.appendingPathComponent("Contents/MacOS").appendingPathComponent(name).path
            guard let executable = FileIdentity(path: executablePath) else { return nil }
            self.path = url.path
            self.version = version
            self.directory = directory
            self.executablePath = executablePath
            self.executable = executable
        }
    }

    private struct FileIdentity: Hashable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int

        init?(path: String) {
            var info = stat()
            guard stat(path, &info) == 0 else { return nil }
            self.device = info.st_dev
            self.inode = info.st_ino
            self.size = info.st_size
            self.modifiedSeconds = info.st_mtimespec.tv_sec
            self.modifiedNanoseconds = info.st_mtimespec.tv_nsec
        }
    }
}
#endif
