import Darwin
import Dispatch
import Foundation

final class CodexSessionsWatcher {
    let watchedPaths: [String]
    private(set) var isWatching: Bool = false

    private let queue = DispatchQueue(label: "com.steipete.CodexBar.codexSessionsWatcher", qos: .utility)
    private var descriptors: [CInt] = []
    private var sources: [DispatchSourceFileSystemObject] = []
    private let onChange: @Sendable () -> Void

    init(urls: [URL], onChange: @escaping @Sendable () -> Void) {
        self.watchedPaths = urls.map(\.path).sorted()
        self.onChange = onChange
        self.start(urls: urls)
        self.isWatching = !self.sources.isEmpty
    }

    deinit {
        self.stop()
    }

    private func start(urls: [URL]) {
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            let descriptor = Darwin.open(url.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .extend, .delete, .rename, .attrib, .link, .revoke],
                queue: self.queue)

            source.setEventHandler { [onChange = self.onChange] in
                onChange()
            }
            source.setCancelHandler {
                Darwin.close(descriptor)
            }
            source.resume()

            self.descriptors.append(descriptor)
            self.sources.append(source)
        }
    }

    private func stop() {
        let activeSources = self.sources
        self.sources.removeAll()
        self.descriptors.removeAll()
        activeSources.forEach { $0.cancel() }
    }
}
