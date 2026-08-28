import CodexBarCore
import Foundation

final class ConfigFileWatcher: @unchecked Sendable {
    typealias ChangeHandler = @Sendable () -> Void

    private let fileURL: URL
    private let queue: DispatchQueue
    private let changeHandler: ChangeHandler
    private let lock = NSLock()
    private var source: DispatchSourceFileSystemObject?
    private var expectedAppWriteHash: String?
    private var stopped = false

    init(fileURL: URL, changeHandler: @escaping ChangeHandler) {
        self.fileURL = fileURL
        self.queue = DispatchQueue(label: "com.steipete.codexbar.config-file-watcher", qos: .utility)
        self.changeHandler = changeHandler
    }

    func start() {
        self.queue.async { [weak self] in
            self?.arm()
        }
    }

    func stop() {
        self.lock.withLock {
            self.stopped = true
        }
        self.queue.async { [weak self] in
            self?.source?.cancel()
            self?.source = nil
        }
    }

    func noteAppWrite(data: Data) {
        self.lock.withLock {
            self.expectedAppWriteHash = CanonicalSyncJSON.hash(data: data)
        }
    }

    private func arm() {
        guard !self.lock.withLock({ self.stopped }) else { return }
        self.source?.cancel()
        self.source = nil

        let watchedURL = FileManager.default.fileExists(atPath: self.fileURL.path)
            ? self.fileURL
            : self.fileURL.deletingLastPathComponent()
        let descriptor = open(watchedURL.path, O_EVTONLY)
        guard descriptor >= 0 else {
            self.queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.arm() }
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .rename, .delete],
            queue: self.queue)
        source.setEventHandler { [weak self, weak source] in
            guard let self else { return }
            let flags = source?.data ?? []
            self.processChange()
            if flags.contains(.rename) || flags.contains(.delete) || watchedURL != self.fileURL {
                source?.cancel()
                self.source = nil
                self.queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.arm() }
            }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        self.source = source
        source.resume()
    }

    private func processChange() {
        guard let data = try? Data(contentsOf: self.fileURL) else { return }
        let hash = CanonicalSyncJSON.hash(data: data)
        let isAppWrite = self.lock.withLock { self.expectedAppWriteHash == hash }
        guard !isAppWrite else { return }
        self.changeHandler()
    }
}
