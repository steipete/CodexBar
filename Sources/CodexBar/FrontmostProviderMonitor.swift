import AppKit
import CodexBarCore

@MainActor
protocol FrontmostApplicationEventSource: AnyObject {
    var frontmostBundleIdentifier: String? { get }
    func start(onChange: @escaping @MainActor () -> Void)
    func stop()
}

@MainActor
final class WorkspaceFrontmostApplicationEventSource: FrontmostApplicationEventSource {
    private var observers: [NSObjectProtocol] = []
    private var onChange: (@MainActor () -> Void)?

    var frontmostBundleIdentifier: String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    func start(onChange: @escaping @MainActor () -> Void) {
        guard self.observers.isEmpty else { return }
        self.onChange = onChange
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            let observer = NSWorkspace.shared.notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main)
            { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.onChange?()
                }
            }
            self.observers.append(observer)
        }
    }

    func stop() {
        for observer in self.observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        self.observers.removeAll()
        self.onChange = nil
    }
}

enum NativeAppProviderMapping {
    static func provider(
        for bundleIdentifier: String?,
        enabledProviders: Set<UsageProvider>) -> UsageProvider?
    {
        guard let bundleIdentifier else { return nil }
        let matches = ProviderDescriptorRegistry.all.filter {
            enabledProviders.contains($0.id) && $0.nativeAppBundleIdentifiers.contains(bundleIdentifier)
        }
        return matches.count == 1 ? matches[0].id : nil
    }
}

enum FrontmostProviderMonitoringPolicy {
    static func shouldRun(source: UnifiedIconSource, mergeIcons: Bool, isStacked: Bool) -> Bool {
        source == .frontmostApp && mergeIcons && !isStacked
    }
}

@MainActor
final class FrontmostProviderMonitor {
    private let source: FrontmostApplicationEventSource
    private let enabledProviders: () -> Set<UsageProvider>
    private let onChange: (UsageProvider?) -> Void
    private(set) var isRunning = false
    private(set) var currentProvider: UsageProvider?

    init(
        source: FrontmostApplicationEventSource,
        enabledProviders: @escaping () -> Set<UsageProvider>,
        onChange: @escaping (UsageProvider?) -> Void)
    {
        self.source = source
        self.enabledProviders = enabledProviders
        self.onChange = onChange
    }

    func synchronize(shouldRun: Bool) {
        if shouldRun {
            self.start()
            self.refresh()
        } else {
            self.stop()
        }
    }

    func start() {
        guard !self.isRunning else { return }
        self.isRunning = true
        self.source.start { [weak self] in
            self?.refresh()
        }
        self.refresh()
    }

    func refresh() {
        guard self.isRunning else { return }
        let provider = NativeAppProviderMapping.provider(
            for: self.source.frontmostBundleIdentifier,
            enabledProviders: self.enabledProviders())
        guard provider != self.currentProvider else { return }
        self.currentProvider = provider
        self.onChange(provider)
    }

    func stop() {
        guard self.isRunning else { return }
        self.source.stop()
        self.isRunning = false
        guard self.currentProvider != nil else { return }
        self.currentProvider = nil
        self.onChange(nil)
    }
}
