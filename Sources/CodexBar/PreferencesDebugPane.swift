import AppKit
import CodexBarCore
import SwiftUI

@MainActor
struct DebugPane: View {
    @Bindable var settings: SettingsStore
    @Bindable var store: UsageStore
    @AppStorage("debugFileLoggingEnabled") private var debugFileLoggingEnabled = false
    @State private var currentLogProvider: UsageProvider = .codex
    @State private var currentFetchProvider: UsageProvider = .codex
    @State private var isLoadingLog = false
    @State private var logText: String = ""
    @State private var isClearingCostCache = false
    @State private var costCacheStatus: String?
    #if DEBUG
    @State private var currentErrorProvider: UsageProvider = .codex
    @State private var simulatedErrorText: String = """
    Simulated error for testing layout.
    Second line.
    Third line.
    Fourth line.
    """
    #endif

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 20) {
                SettingsSection(title: "Logging") {
                    PreferenceToggleRow(
                        title: "Enable file logging",
                        subtitle: "Write logs to \(self.fileLogPath) for debugging.",
                        binding: self.$debugFileLoggingEnabled)
                        .onChange(of: self.debugFileLoggingEnabled) { _, newValue in
                            if self.settings.debugFileLoggingEnabled != newValue {
                                self.settings.debugFileLoggingEnabled = newValue
                            }
                        }

                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Verbosity")
                                .font(.body)
                            Text("Controls how much detail is logged.")
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Picker("Verbosity", selection: self.$settings.debugLogLevel) {
                            ForEach(CodexBarLog.Level.allCases) { level in
                                Text(level.displayName).tag(level)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: 160)
                    }

                    Button {
                        NSWorkspace.shared.open(CodexBarLog.fileLogURL)
                    } label: {
                        Label("Open log file", systemImage: "doc.text.magnifyingglass")
                    }
                    .controlSize(.small)
                }

                SettingsSection {
                    PreferenceToggleRow(
                        title: "Force animation on next refresh",
                        subtitle: "Temporarily shows the loading animation after the next refresh.",
                        binding: self.$store.debugForceAnimation)
                }

                SettingsSection(
                    title: "Loading animations",
                    caption: "Pick a pattern and replay it in the menu bar. \"Random\" keeps the existing behavior.")
                {
                    Picker("Animation pattern", selection: self.animationPatternBinding) {
                        Text("Random (default)").tag(nil as LoadingPattern?)
                        ForEach(LoadingPattern.allCases) { pattern in
                            Text(pattern.displayName).tag(Optional(pattern))
                        }
                    }
                    .pickerStyle(.radioGroup)

                    Button("Replay selected animation") {
                        self.replaySelectedAnimation()
                    }
                    .keyboardShortcut(.defaultAction)

                    Button {
                        NotificationCenter.default.post(name: .codexbarDebugBlinkNow, object: nil)
                    } label: {
                        Label("Blink now", systemImage: "eyes")
                    }
                    .controlSize(.small)
                }

                SettingsSection(
                    title: "Probe logs",
                    caption: "Fetch the latest probe output for debugging; Copy keeps the full text.")
                {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Picker("Provider", selection: self.$currentLogProvider) {
                            Text("Codex").tag(UsageProvider.codex)
                            Text("Claude").tag(UsageProvider.claude)
                            Text("Cursor").tag(UsageProvider.cursor)
                            Text("Augment").tag(UsageProvider.augment)
                            Text("Amp").tag(UsageProvider.amp)
                            Text("Antigravity").tag(UsageProvider.antigravity)
                            Text("Ollama").tag(UsageProvider.ollama)
                        }
                        .pickerStyle(.segmented)
                        .controlSize(.small)
                        .fixedSize()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 12) {
                        Button { self.loadLog(self.currentLogProvider) } label: {
                            Label("Fetch log", systemImage: "arrow.clockwise")
                        }
                        .disabled(self.isLoadingLog)

                        Button { self.copyToPasteboard(self.logText) } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        .disabled(self.logText.isEmpty)

                        Button { self.saveLog(self.currentLogProvider) } label: {
                            Label("Save to file", systemImage: "externaldrive.badge.plus")
                        }
                        .disabled(self.isLoadingLog && self.logText.isEmpty)

                        if self.currentLogProvider == .claude {
                            Button { self.loadClaudeDump() } label: {
                                Label("Load parse dump", systemImage: "doc.text.magnifyingglass")
                            }
                            .disabled(self.isLoadingLog)
                        }
                    }

                    Button {
                        self.settings.rerunProviderDetection()
                        self.loadLog(self.currentLogProvider)
                    } label: {
                        Label("Re-run provider autodetect", systemImage: "dot.radiowaves.left.and.right")
                    }
                    .controlSize(.small)

                    ZStack(alignment: .topLeading) {
                        ScrollView {
                            Text(self.displayedLog)
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                        }
                        .frame(minHeight: 160, maxHeight: 220)
                        .background(Color(NSColor.textBackgroundColor))
                        .cornerRadius(6)

                        if self.isLoadingLog {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                                .padding()
                        }
                    }
                }

                SettingsSection(
                    title: "Fetch strategy attempts",
                    caption: "Last fetch pipeline decisions and errors for a provider.")
                {
                    Picker("Provider", selection: self.$currentFetchProvider) {
                        ForEach(UsageProvider.allCases, id: \.self) { provider in
                            Text(provider.rawValue.capitalized).tag(provider)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 240)

                    ScrollView {
                        Text(self.fetchAttemptsText(for: self.currentFetchProvider))
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(minHeight: 120, maxHeight: 220)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(6)
                }

                if !self.settings.debugDisableKeychainAccess {
                    SettingsSection(
                        title: "OpenAI cookies",
                        caption: "Cookie import + WebKit scrape logs from the last OpenAI cookies attempt.")
                    {
                        HStack(spacing: 12) {
                            Button {
                                self.copyToPasteboard(self.store.openAIDashboardCookieImportDebugLog ?? "")
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                            .disabled((self.store.openAIDashboardCookieImportDebugLog ?? "").isEmpty)
                        }

                        ScrollView {
                            Text(
                                self.store.openAIDashboardCookieImportDebugLog?.isEmpty == false
                                    ? (self.store.openAIDashboardCookieImportDebugLog ?? "")
                                    : "No log yet. Update OpenAI cookies in Providers → Codex to run an import.")
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                        }
                        .frame(minHeight: 120, maxHeight: 180)
                        .background(Color(NSColor.textBackgroundColor))
                        .cornerRadius(6)
                    }
                }

                SettingsSection(
                    title: "Caches",
                    caption: "Clear cached cost scan results.")
                {
                    let isTokenRefreshActive = self.store.isTokenRefreshInFlight(for: .codex)
                        || self.store.isTokenRefreshInFlight(for: .claude)

                    HStack(spacing: 12) {
                        Button {
                            Task { await self.clearCostCache() }
                        } label: {
                            Label("Clear cost cache", systemImage: "trash")
                        }
                        .disabled(self.isClearingCostCache || isTokenRefreshActive)

                        if let status = self.costCacheStatus {
                            Text(status)
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                SettingsSection(
                    title: "Notifications",
                    caption: "Trigger test notifications for the 5-hour session window (depleted/restored).")
                {
                    Picker("Provider", selection: self.$currentLogProvider) {
                        Text("Codex").tag(UsageProvider.codex)
                        Text("Claude").tag(UsageProvider.claude)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 240)

                    HStack(spacing: 12) {
                        Button {
                            self.postSessionNotification(.depleted, provider: self.currentLogProvider)
                        } label: {
                            Label("Post depleted", systemImage: "bell.badge")
                        }
                        .controlSize(.small)

                        Button {
                            self.postSessionNotification(.restored, provider: self.currentLogProvider)
                        } label: {
                            Label("Post restored", systemImage: "bell")
                        }
                        .controlSize(.small)
                    }
                }

                SettingsSection(
                    title: "CLI sessions",
                    caption: "Keep Codex/Claude CLI sessions alive after a probe. Default exits once data is captured.")
                {
                    PreferenceToggleRow(
                        title: "Keep CLI sessions alive",
                        subtitle: "Skip teardown between probes (debug-only).",
                        binding: self.$settings.debugKeepCLISessionsAlive)

                    Button {
                        Task {
                            await CLIProbeSessionResetter.resetAll()
                        }
                    } label: {
                        Label("Reset CLI sessions", systemImage: "arrow.counterclockwise")
                    }
                    .controlSize(.small)
                }

                #if DEBUG
                SettingsSection(
                    title: "Error simulation",
                    caption: "Inject a fake error message into the menu card for layout testing.")
                {
                    Picker("Provider", selection: self.$currentErrorProvider) {
                        Text("Codex").tag(UsageProvider.codex)
                        Text("Claude").tag(UsageProvider.claude)
                        Text("Gemini").tag(UsageProvider.gemini)
                        Text("Antigravity").tag(UsageProvider.antigravity)
                        Text("Augment").tag(UsageProvider.augment)
                        Text("Amp").tag(UsageProvider.amp)
                        Text("Ollama").tag(UsageProvider.ollama)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 360)

                    TextField("Simulated error text", text: self.$simulatedErrorText, axis: .vertical)
                        .lineLimit(4)

                    HStack(spacing: 12) {
                        Button {
                            self.store._setErrorForTesting(
                                self.simulatedErrorText,
                                provider: self.currentErrorProvider)
                        } label: {
                            Label("Set menu error", systemImage: "exclamationmark.triangle")
                        }
                        .controlSize(.small)

                        Button {
                            self.store._setErrorForTesting(nil, provider: self.currentErrorProvider)
                        } label: {
                            Label("Clear menu error", systemImage: "xmark.circle")
                        }
                        .controlSize(.small)
                    }

                    let supportsTokenError = self.currentErrorProvider == .codex || self.currentErrorProvider == .claude
                    HStack(spacing: 12) {
                        Button {
                            self.store._setTokenErrorForTesting(
                                self.simulatedErrorText,
                                provider: self.currentErrorProvider)
                        } label: {
                            Label("Set cost error", systemImage: "banknote")
                        }
                        .controlSize(.small)
                        .disabled(!supportsTokenError)

                        Button {
                            self.store._setTokenErrorForTesting(nil, provider: self.currentErrorProvider)
                        } label: {
                            Label("Clear cost error", systemImage: "xmark.circle")
                        }
                        .controlSize(.small)
                        .disabled(!supportsTokenError)
                    }
                }
                #endif

                SettingsSection(
                    title: "CLI paths",
                    caption: "Resolved Codex binary and PATH layers; startup login PATH capture (short timeout).")
                {
                    self.binaryRow(title: "Codex binary", value: self.store.pathDebugInfo.codexBinary)
                    self.binaryRow(title: "Claude binary", value: self.store.pathDebugInfo.claudeBinary)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Effective PATH")
                            .font(.callout.weight(.semibold))
                        ScrollView {
                            Text(
                                self.store.pathDebugInfo.effectivePATH.isEmpty
                                    ? "Unavailable"
                                    : self.store.pathDebugInfo.effectivePATH)
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(6)
                        }
                        .frame(minHeight: 60, maxHeight: 110)
                        .background(Color(NSColor.textBackgroundColor))
                        .cornerRadius(6)
                    }

                    if let loginPATH = self.store.pathDebugInfo.loginShellPATH {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Login shell PATH (startup capture)")
                                .font(.callout.weight(.semibold))
                            ScrollView {
                                Text(loginPATH)
                                    .font(.system(.footnote, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(6)
                            }
                            .frame(minHeight: 60, maxHeight: 110)
                            .background(Color(NSColor.textBackgroundColor))
                            .cornerRadius(6)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    private var fileLogPath: String {
        CodexBarLog.fileLogURL.path
    }

    private var animationPatternBinding: Binding<LoadingPattern?> {
        Binding(
            get: { self.settings.debugLoadingPattern },
            set: { self.settings.debugLoadingPattern = $0 })
    }

    private func replaySelectedAnimation() {
        var userInfo: [AnyHashable: Any] = [:]
        if let pattern = self.settings.debugLoadingPattern {
            userInfo["pattern"] = pattern.rawValue
        }
        NotificationCenter.default.post(
            name: .codexbarDebugReplayAllAnimations,
            object: nil,
            userInfo: userInfo.isEmpty ? nil : userInfo)
        self.store.replayLoadingAnimation(duration: 4)
    }

    private var displayedLog: String {
        if self.logText.isEmpty {
            return self.isLoadingLog ? "Loading…" : "No log yet. Fetch to load."
        }
        return self.logText
    }

    private func loadLog(_ provider: UsageProvider) {
        self.isLoadingLog = true
        Task {
            let text = await self.store.debugLog(for: provider)
            await MainActor.run {
                self.logText = text
                self.isLoadingLog = false
            }
        }
    }

    private func saveLog(_ provider: UsageProvider) {
        Task {
            if self.logText.isEmpty {
                self.isLoadingLog = true
                let text = await self.store.debugLog(for: provider)
                await MainActor.run { self.logText = text }
                self.isLoadingLog = false
            }
            _ = await self.store.dumpLog(toFileFor: provider)
        }
    }

    private func copyToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func binaryRow(title: String, value: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.callout.weight(.semibold))
            Text(value ?? "Not found")
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(value == nil ? .secondary : .primary)
        }
    }

    private func loadClaudeDump() {
        self.isLoadingLog = true
        Task {
            let text = await self.store.debugClaudeDump()
            await MainActor.run {
                self.logText = text
                self.isLoadingLog = false
            }
        }
    }

    private func postSessionNotification(_ transition: SessionQuotaTransition, provider: UsageProvider) {
        SessionQuotaNotifier().post(transition: transition, provider: provider, badge: 1)
    }

    private func clearCostCache() async {
        guard !self.isClearingCostCache else { return }
        self.isClearingCostCache = true
        self.costCacheStatus = nil
        defer { self.isClearingCostCache = false }

        if let error = await self.store.clearCostUsageCache() {
            self.costCacheStatus = "Failed: \(error)"
            return
        }

        self.costCacheStatus = "Cleared."
    }

    private func fetchAttemptsText(for provider: UsageProvider) -> String {
        let attempts = self.store.fetchAttempts(for: provider)
        guard !attempts.isEmpty else { return "No fetch attempts yet." }
        return attempts.map { attempt in
            let kind = Self.fetchKindLabel(attempt.kind)
            var line = "\(attempt.strategyID) (\(kind))"
            line += attempt.wasAvailable ? " available" : " unavailable"
            if let error = attempt.errorDescription, !error.isEmpty {
                line += " error=\(error)"
            }
            return line
        }.joined(separator: "\n")
    }

    private static func fetchKindLabel(_ kind: ProviderFetchKind) -> String {
        switch kind {
        case .cli: "cli"
        case .web: "web"
        case .oauth: "oauth"
        case .apiToken: "api"
        case .localProbe: "local"
        case .webDashboard: "web"
        }
    }
}
