import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
struct FrontmostProviderMonitorTests {
    @Test
    func `monitor only runs while frontmost source can affect the collapsed merged icon`() {
        #expect(FrontmostProviderMonitoringPolicy.shouldRun(
            source: .frontmostApp, mergeIcons: true, isStacked: false))
        for source in [UnifiedIconSource.currentSelection, .highestUsage] {
            #expect(!FrontmostProviderMonitoringPolicy.shouldRun(
                source: source, mergeIcons: true, isStacked: false))
        }
        #expect(!FrontmostProviderMonitoringPolicy.shouldRun(
            source: .frontmostApp, mergeIcons: false, isStacked: false))
        #expect(!FrontmostProviderMonitoringPolicy.shouldRun(
            source: .frontmostApp, mergeIcons: true, isStacked: true))
    }

    @Test
    func `presentation changes unregister and reseed the focus observer`() {
        let source = FakeFrontmostApplicationEventSource(bundleIdentifier: "com.openai.codex")
        var changes: [UsageProvider?] = []
        let monitor = FrontmostProviderMonitor(
            source: source,
            enabledProviders: { [.codex, .claude] },
            onChange: { changes.append($0) })

        func synchronize(_ iconSource: UnifiedIconSource, mergeIcons: Bool, isStacked: Bool) {
            monitor.synchronize(shouldRun: FrontmostProviderMonitoringPolicy.shouldRun(
                source: iconSource, mergeIcons: mergeIcons, isStacked: isStacked))
        }

        synchronize(.frontmostApp, mergeIcons: true, isStacked: false)
        #expect(source.startCount == 1)
        #expect(monitor.currentProvider == .codex)

        synchronize(.frontmostApp, mergeIcons: false, isStacked: false)
        #expect(source.stopCount == 1)
        #expect(!monitor.isRunning)
        source.activate("com.anthropic.claudefordesktop")
        #expect(changes == [.codex, nil])

        synchronize(.frontmostApp, mergeIcons: true, isStacked: false)
        #expect(source.startCount == 2)
        #expect(monitor.currentProvider == .claude)

        synchronize(.frontmostApp, mergeIcons: true, isStacked: true)
        #expect(source.stopCount == 2)
        synchronize(.currentSelection, mergeIcons: true, isStacked: false)
        #expect(source.startCount == 2)

        synchronize(.frontmostApp, mergeIcons: true, isStacked: false)
        #expect(source.startCount == 3)
        #expect(monitor.currentProvider == .claude)
        monitor.stop()
        #expect(source.stopCount == 3)
    }

    @Test
    func `only provider owned native apps match enabled providers`() {
        let enabled: Set<UsageProvider> = [.codex, .claude, .antigravity, .cursor, .zed, .kiro, .qoder, .copilot]
        #expect(NativeAppProviderMapping.provider(for: "com.openai.codex", enabledProviders: enabled) == .codex)
        #expect(NativeAppProviderMapping.provider(
            for: "com.anthropic.claudefordesktop", enabledProviders: enabled) == .claude)
        #expect(NativeAppProviderMapping.provider(
            for: "com.google.antigravity", enabledProviders: enabled) == .antigravity)
        #expect(NativeAppProviderMapping.provider(for: "com.qoder.app", enabledProviders: enabled) == nil)
        #expect(NativeAppProviderMapping.provider(
            for: "com.todesktop.230313mzl4w4u92", enabledProviders: enabled) == nil)
        #expect(NativeAppProviderMapping.provider(for: "dev.zed.Zed", enabledProviders: enabled) == nil)
        #expect(NativeAppProviderMapping.provider(for: "dev.kiro.desktop", enabledProviders: enabled) == nil)
        #expect(NativeAppProviderMapping.provider(for: "com.qoder.ide", enabledProviders: enabled) == nil)
        #expect(NativeAppProviderMapping.provider(for: "com.microsoft.VSCode", enabledProviders: enabled) == nil)
        #expect(NativeAppProviderMapping.provider(for: "com.apple.Safari", enabledProviders: enabled) == nil)
        #expect(NativeAppProviderMapping.provider(for: "com.openai.codex", enabledProviders: [.claude]) == nil)
        #expect(NativeAppProviderMapping.provider(for: "com.google.antigravity", enabledProviders: [.codex]) == nil)
    }

    @Test
    func `monitor seeds coalesces refreshes and unregisters on stop`() {
        let source = FakeFrontmostApplicationEventSource(bundleIdentifier: "com.openai.codex")
        var enabled: Set<UsageProvider> = [.codex, .claude]
        var changes: [UsageProvider?] = []
        let monitor = FrontmostProviderMonitor(
            source: source,
            enabledProviders: { enabled },
            onChange: { changes.append($0) })

        monitor.start()
        #expect(source.startCount == 1)
        #expect(monitor.currentProvider == .codex)
        #expect(changes == [.codex])

        source.activate("com.openai.codex")
        monitor.start()
        #expect(source.startCount == 1)
        #expect(changes == [.codex])

        source.activate("com.anthropic.claudefordesktop")
        #expect(changes == [.codex, .claude])
        source.activate("com.apple.Safari")
        #expect(changes == [.codex, .claude, nil])
        source.activate("com.openai.codex")
        enabled.remove(.codex)
        monitor.refresh()
        #expect(changes == [.codex, .claude, nil, .codex, nil])

        monitor.stop()
        #expect(source.stopCount == 1)
        #expect(!monitor.isRunning)
        source.activate("com.anthropic.claudefordesktop")
        #expect(changes == [.codex, .claude, nil, .codex, nil])
    }

    @Test
    func `termination falls back and a new activation restores the match`() {
        let source = FakeFrontmostApplicationEventSource(bundleIdentifier: "com.openai.codex")
        var changes: [UsageProvider?] = []
        let monitor = FrontmostProviderMonitor(
            source: source,
            enabledProviders: { [.codex, .claude] },
            onChange: { changes.append($0) })

        monitor.start()
        source.terminateFrontmost()
        source.activate("com.anthropic.claudefordesktop")

        #expect(changes == [.codex, nil, .claude])
        monitor.stop()
        #expect(changes == [.codex, nil, .claude, nil])
    }

    @Test
    func `frontmost match overrides only the collapsed merged icon`() {
        let fallback = UsageProvider.copilot
        let enabled: Set<UsageProvider> = [.codex, .copilot]
        let active = UnifiedIconContext(
            source: .frontmostApp,
            focusedProvider: .codex,
            isMergedMenuOpen: false,
            isStacked: false)
        #expect(active.resolve(fallback: fallback, mergeIcons: true, enabledProviders: enabled) == .codex)
        #expect(active.resolve(fallback: fallback, mergeIcons: false, enabledProviders: enabled) == fallback)
        #expect(active.resolve(fallback: fallback, mergeIcons: true, enabledProviders: [.copilot]) == fallback)

        for source in [UnifiedIconSource.currentSelection, .highestUsage] {
            let context = UnifiedIconContext(
                source: source,
                focusedProvider: .codex,
                isMergedMenuOpen: false,
                isStacked: false)
            #expect(context.resolve(fallback: fallback, mergeIcons: true, enabledProviders: enabled) == fallback)
        }
        for (menuOpen, stacked) in [(true, false), (false, true)] {
            let context = UnifiedIconContext(
                source: .frontmostApp,
                focusedProvider: .codex,
                isMergedMenuOpen: menuOpen,
                isStacked: stacked)
            #expect(context.resolve(fallback: fallback, mergeIcons: true, enabledProviders: enabled) == fallback)
        }
        let unknown = UnifiedIconContext(
            source: .frontmostApp,
            focusedProvider: nil,
            isMergedMenuOpen: false,
            isStacked: false)
        #expect(unknown.resolve(fallback: fallback, mergeIcons: true, enabledProviders: enabled) == fallback)
    }
}

@MainActor
private final class FakeFrontmostApplicationEventSource: FrontmostApplicationEventSource {
    var frontmostBundleIdentifier: String?
    var startCount = 0
    var stopCount = 0
    private var onChange: (@MainActor () -> Void)?

    init(bundleIdentifier: String?) {
        self.frontmostBundleIdentifier = bundleIdentifier
    }

    func start(onChange: @escaping @MainActor () -> Void) {
        self.startCount += 1
        self.onChange = onChange
    }

    func stop() {
        self.stopCount += 1
        self.onChange = nil
    }

    func activate(_ bundleIdentifier: String?) {
        self.frontmostBundleIdentifier = bundleIdentifier
        self.onChange?()
    }

    func terminateFrontmost() {
        self.activate(nil)
    }
}
