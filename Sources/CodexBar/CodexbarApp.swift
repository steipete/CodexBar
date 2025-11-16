import AppKit
import Combine
import ServiceManagement
import Sparkle
import SwiftUI

// MARK: - Settings

enum RefreshFrequency: String, CaseIterable, Identifiable {
    case manual
    case oneMinute
    case twoMinutes
    case fiveMinutes

    var id: String { self.rawValue }

    var seconds: TimeInterval? {
        switch self {
        case .manual: nil
        case .oneMinute: 60
        case .twoMinutes: 120
        case .fiveMinutes: 300
        }
    }

    var label: String {
        switch self {
        case .manual: "Manual"
        case .oneMinute: "1 min"
        case .twoMinutes: "2 min"
        case .fiveMinutes: "5 min"
        }
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    @Published var refreshFrequency: RefreshFrequency {
        didSet { UserDefaults.standard.set(self.refreshFrequency.rawValue, forKey: "refreshFrequency") }
    }

    @AppStorage("launchAtLogin") var launchAtLogin: Bool = false {
        // Keep SMLoginItem state in sync with the toggle.
        didSet { LaunchAtLoginManager.setEnabled(self.launchAtLogin) }
    }

    init(userDefaults: UserDefaults = .standard) {
        let raw = userDefaults.string(forKey: "refreshFrequency") ?? RefreshFrequency.twoMinutes.rawValue
        self.refreshFrequency = RefreshFrequency(rawValue: raw) ?? .twoMinutes
        // Apply stored login preference immediately on launch.
        LaunchAtLoginManager.setEnabled(self.launchAtLogin)
    }
}

// MARK: - Usage Store

@MainActor
final class UsageStore: ObservableObject {
    @Published var snapshot: UsageSnapshot?
    @Published var lastError: String?
    @Published var isRefreshing = false

    private let fetcher: UsageFetcher
    private let settings: SettingsStore
    private var timerTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(fetcher: UsageFetcher, settings: SettingsStore) {
        self.fetcher = fetcher
        self.settings = settings
        self.bindSettings()
        Task { await self.refresh() }
        self.startTimer()
    }

    func refresh() async {
        guard !self.isRefreshing else { return }
        self.isRefreshing = true
        defer { self.isRefreshing = false }

        do {
            let usage = try await self.fetcher.loadLatestUsage()
            self.snapshot = usage
            self.lastError = nil
        } catch {
            self.lastError = error.localizedDescription
        }
    }

    private func bindSettings() {
        self.settings.$refreshFrequency
            .sink { [weak self] _ in
                self?.startTimer()
            }
            .store(in: &self.cancellables)
    }

    private func startTimer() {
        self.timerTask?.cancel()
        guard let wait = self.settings.refreshFrequency.seconds else { return }

        // Detached poller so the menu stays responsive while waiting.
        self.timerTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(wait))
                await self?.refresh()
            }
        }
    }

    deinit {
        self.timerTask?.cancel()
    }
}

// MARK: - UI

struct UsageRow: View {
    let title: String
    let window: RateWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(self.title).font(.headline)
            let usageText = String(
                format: "%.0f%% left (%.0f%% used)",
                self.window.remainingPercent,
                self.window.usedPercent)
            Text(usageText)
            if let reset = window.resetsAt {
                Text("Resets \(reset.formatted(date: .abbreviated, time: .shortened))")
            }
        }
    }
}

struct MenuContent: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: SettingsStore
    let account: AccountInfo
    let updater: SPUStandardUpdaterController

    private var autoUpdateBinding: Binding<Bool> {
        Binding(
            get: { self.updater.updater.automaticallyChecksForUpdates },
            set: { self.updater.updater.automaticallyChecksForUpdates = $0 })
    }

    private var snapshot: UsageSnapshot? { self.store.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let snapshot {
                UsageRow(title: "5h limit", window: snapshot.primary)
                UsageRow(title: "Weekly limit", window: snapshot.secondary)
                Text("Updated \(snapshot.updatedAt.formatted(date: .omitted, time: .shortened))")
                    .foregroundStyle(.secondary)
            } else {
                Text("No usage yet").foregroundStyle(.secondary)
                if let error = store.lastError { Text(error).font(.caption) }
            }

            Divider()
            if let email = account.email {
                Text("Account: \(email)")
                    .foregroundStyle(.secondary)
            } else {
                Text("Account: unknown")
                    .foregroundStyle(.secondary)
            }
            if let plan = account.plan {
                Text("Plan: \(plan.capitalized)")
                    .foregroundStyle(.secondary)
            }

            Button {
                Task { await self.store.refresh() }
            } label: {
                Text(self.store.isRefreshing ? "Refreshing…" : "Refresh now")
            }
            .disabled(self.store.isRefreshing)
            .buttonStyle(.plain)
            Divider()
            Menu("Settings") {
                Menu("Refresh every: \(self.settings.refreshFrequency.label)") {
                    ForEach(RefreshFrequency.allCases) { option in
                        Button {
                            self.settings.refreshFrequency = option
                        } label: {
                            if self.settings.refreshFrequency == option {
                                Label(option.label, systemImage: "checkmark")
                            } else {
                                Text(option.label)
                            }
                        }
                    }
                }
                Toggle("Automatically check for updates", isOn: self.autoUpdateBinding)
                Toggle("Launch at login", isOn: self.$settings.launchAtLogin)
                Button("Check for Updates…") {
                    self.updater.checkForUpdates(nil)
                }
            }
            .buttonStyle(.plain)
            Button("About CodexBar") {
                showAbout()
            }
            .buttonStyle(.plain)
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minWidth: 240, alignment: .leading)
        .foregroundStyle(.primary)
        if self.settings.refreshFrequency == .manual {
            Text("Auto-refresh is off")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
        }
    }
}

@main
struct CodexBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings = SettingsStore()
    @StateObject private var store: UsageStore
    private let account: AccountInfo
    @State private var isInserted = true

    init() {
        let settings = SettingsStore()
        let fetcher = UsageFetcher()
        self.account = fetcher.loadAccountInfo()
        _settings = StateObject(wrappedValue: settings)
        _store = StateObject(wrappedValue: UsageStore(fetcher: fetcher, settings: settings))
    }

    var body: some Scene {
        MenuBarExtra(isInserted: self.$isInserted) {
            MenuContent(
                store: self.store,
                settings: self.settings,
                account: self.account,
                updater: self.appDelegate.updaterController)
        } label: {
            IconView(snapshot: self.store.snapshot, isStale: self.store.lastError != nil)
        }
        Settings {
            EmptyView()
        }
    }
}

struct IconView: View {
    let snapshot: UsageSnapshot?
    let isStale: Bool
    @State private var phase: CGFloat = 0
    private let displayLink = DisplayLink()

    var body: some View {
        Group {
            if let snapshot {
                Image(nsImage: IconRenderer.makeIcon(
                    primaryRemaining: snapshot.primary.remainingPercent,
                    weeklyRemaining: snapshot.secondary.remainingPercent,
                    stale: self.isStale))
            } else {
                Image(nsImage: IconRenderer.makeIcon(
                    primaryRemaining: self.loadingValue,
                    weeklyRemaining: self.loadingValue * 0.6,
                    stale: false))
                    .onReceive(self.displayLink.publisher) { _ in
                        self.phase += 0.08
                    }
            }
        }
    }

    private var loadingValue: Double {
        // Simple oscillating fill 20–90%
        let v = 0.55 + 0.35 * sin(Double(self.phase))
        return max(0, min(v * 100, 100))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil)
}

@MainActor
private func showAbout() {
    NSApp.activate(ignoringOtherApps: true)

    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    let versionString = build.isEmpty ? version : "\(version) (\(build))"

    let credits = NSMutableAttributedString(string: "Peter Steinberger — MIT License\n")
    credits.append(makeLink("GitHub", urlString: "https://github.com/steipete/CodexBar"))
    credits.append(NSAttributedString(string: "\n"))
    credits.append(makeLink("Website", urlString: "https://steipete.me"))
    credits.append(NSAttributedString(string: "\n"))
    credits.append(makeLink("Twitter", urlString: "https://twitter.com/steipete"))
    credits.append(NSAttributedString(string: "\n"))
    credits.append(makeLink("Email", urlString: "mailto:peter@steipete.me"))

    let options: [NSApplication.AboutPanelOptionKey: Any] = [
        .applicationName: "CodexBar",
        .applicationVersion: versionString,
        .version: versionString,
        .credits: credits,
        // Use bundled icon if available; fallback to empty image to avoid nil coercion warnings.
        .applicationIcon: (NSApplication.shared.applicationIconImage ?? NSImage()) as Any,
    ]

    NSApp.orderFrontStandardAboutPanel(options: options)

    func makeLink(_ title: String, urlString: String) -> NSAttributedString {
        NSAttributedString(string: title, attributes: [
            .link: URL(string: urlString) as Any,
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
        ])
    }
}

enum LaunchAtLoginManager {
    @MainActor
    static func setEnabled(_ enabled: Bool) {
        guard #available(macOS 13, *) else { return }
        let service = SMAppService.mainApp
        if enabled {
            // Idempotent; safe to call repeatedly.
            try? service.register()
        } else {
            try? service.unregister()
        }
    }
}
