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
    @State private var cookieCacheStatus: String?
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
                SettingsSection(title: L("section_logging")) {
                    PreferenceToggleRow(
                        title: L("enable_file_logging"),
                        subtitle: String(format: L("enable_file_logging_subtitle"), self.fileLogPath),
                        binding: self.$debugFileLoggingEnabled)
                        .onChange(of: self.debugFileLoggingEnabled) { _, newValue in
                            if self.settings.debugFileLoggingEnabled != newValue {
                                self.settings.debugFileLoggingEnabled = newValue
                            }
                        }

                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L("verbosity_title"))
                                .font(.body)
                            Text(L("verbosity_subtitle"))
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
                        Label(L("open_log_file"), systemImage: "doc.text.magnifyingglass")
                    }
                    .controlSize(.small)
                }

                SettingsSection {
                    PreferenceToggleRow(
                        title: L("force_animation_next_refresh"),
                        subtitle: L("force_animation_next_refresh_subtitle"),
                        binding: self.$store.debugForceAnimation)
                }

                SettingsSection(
                    title: L("section_loading_animations"),
                    caption: L("loading_animations_caption"))
                {
                    Picker("Animation pattern", selection: self.animationPatternBinding) {
                        Text(L("animation_random_default")).tag(nil as LoadingPattern?)
                        ForEach(LoadingPattern.allCases) { pattern in
                            Text(pattern.displayName).tag(Optional(pattern))
                        }
                    }
                    .pickerStyle(.radioGroup)

                    Button(L("replay_selected_animation")) {
                        self.replaySelectedAnimation()
                    }
                    .keyboardShortcut(.defaultAction)

                    Button {
                        NotificationCenter.default.post(name: .codexbarDebugBlinkNow, object: nil)
                    } label: {
                        Label(L("blink_now"), systemImage: "eyes")
                    }
                    .controlSize(.small)
                }

                SettingsSection(
                    title: L("section_probe_logs"),
                    caption: L("probe_logs_caption"))
                {
                    Picker("Provider", selection: self.$currentLogProvider) {
                        Text("Codex").tag(UsageProvider.codex)
                        Text("Claude").tag(UsageProvider.claude)
                        Text("Cursor").tag(UsageProvider.cursor)
                        Text("Augment").tag(UsageProvider.augment)
                        Text("Amp").tag(UsageProvider.amp)
                        Text("Ollama").tag(UsageProvider.ollama)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 460)

                    HStack(spacing: 12) {
                        Button { self.loadLog(self.currentLogProvider) } label: {
                            Label(L("fetch_log"), systemImage: "arrow.clockwise")
                        }
                        .disabled(self.isLoadingLog)

                        Button { self.copyToPasteboard(self.logText) } label: {
                            Label(L("copy"), systemImage: "doc.on.doc")
                        }
                        .disabled(self.logText.isEmpty)

                        Button { self.saveLog(self.currentLogProvider) } label: {
                            Label(L("save_to_file"), systemImage: "externaldrive.badge.plus")
                        }
                        .disabled(self.isLoadingLog && self.logText.isEmpty)

                        if self.currentLogProvider == .claude {
                            Button { self.loadClaudeDump() } label: {
                                Label(L("load_parse_dump"), systemImage: "doc.text.magnifyingglass")
                            }
                            .disabled(self.isLoadingLog)
                        }
                    }

                    Button {
                        self.settings.rerunProviderDetection()
                        self.loadLog(self.currentLogProvider)
                    } label: {
                        Label(L("rerun_provider_autodetect"), systemImage: "dot.radiowaves.left.and.right")
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
                    title: L("section_fetch_strategy"),
                    caption: L("fetch_strategy_caption"))
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
                        title: L("section_openai_cookies"),
                        caption: L("openai_cookies_caption"))
                    {
                        HStack(spacing: 12) {
                            Button {
                                self.copyToPasteboard(self.store.openAIDashboardCookieImportDebugLog ?? "")
                            } label: {
                                Label(L("copy"), systemImage: "doc.on.doc")
                            }
                            .disabled((self.store.openAIDashboardCookieImportDebugLog ?? "").isEmpty)
                        }

                        ScrollView {
                            Text(
                                self.store.openAIDashboardCookieImportDebugLog?.isEmpty == false
                                    ? (self.store.openAIDashboardCookieImportDebugLog ?? "")
                                    : L("no_log_yet"))
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
                    title: L("section_caches"),
                    caption: L("caches_caption"))
                {
                    let isTokenRefreshActive = self.store.isTokenRefreshInFlight(for: .codex)
                        || self.store.isTokenRefreshInFlight(for: .claude)

                    HStack(spacing: 12) {
                        Button {
                            Task { await self.clearCostCache() }
                        } label: {
                            Label(L("clear_cost_cache"), systemImage: "trash")
                        }
                        .disabled(self.isClearingCostCache || isTokenRefreshActive)

                        if let status = self.costCacheStatus {
                            Text(status)
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    HStack(spacing: 12) {
                        Button {
                            self.clearCookieCache()
                        } label: {
                            Label(L("clear_cookie_cache"), systemImage: "trash")
                        }

                        if let status = self.cookieCacheStatus {
                            Text(status)
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                SettingsSection(
                    title: L("section_notifications"),
                    caption: L("notifications_caption"))
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
                            Label(L("post_depleted"), systemImage: "bell.badge")
                        }
                        .controlSize(.small)

                        Button {
                            self.postSessionNotification(.restored, provider: self.currentLogProvider)
                        } label: {
                            Label(L("post_restored"), systemImage: "bell")
                        }
                        .controlSize(.small)
                    }
                }

                SettingsSection(
                    title: L("section_cli_sessions"),
                    caption: L("cli_sessions_caption"))
                {
                    PreferenceToggleRow(
                        title: L("keep_cli_sessions_alive"),
                        subtitle: L("keep_cli_sessions_alive_subtitle"),
                        binding: self.$settings.debugKeepCLISessionsAlive)

                    Button {
                        Task {
                            await CLIProbeSessionResetter.resetAll()
                        }
                    } label: {
                        Label(L("reset_cli_sessions"), systemImage: "arrow.counterclockwise")
                    }
                    .controlSize(.small)
                }

                #if DEBUG
                SettingsSection(
                    title: L("section_error_simulation"),
                    caption: L("error_simulation_caption"))
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
                            Label(L("set_menu_error"), systemImage: "exclamationmark.triangle")
                        }
                        .controlSize(.small)

                        Button {
                            self.store._setErrorForTesting(nil, provider: self.currentErrorProvider)
                        } label: {
                            Label(L("clear_menu_error"), systemImage: "xmark.circle")
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
                            Label(L("set_cost_error"), systemImage: "banknote")
                        }
                        .controlSize(.small)
                        .disabled(!supportsTokenError)

                        Button {
                            self.store._setTokenErrorForTesting(nil, provider: self.currentErrorProvider)
                        } label: {
                            Label(L("clear_cost_error"), systemImage: "xmark.circle")
                        }
                        .controlSize(.small)
                        .disabled(!supportsTokenError)
                    }
                }
                #endif

                SettingsSection(
                    title: L("section_cli_paths"),
                    caption: L("cli_paths_caption"))
                {
                    self.binaryRow(title: L("codex_binary"), value: self.store.pathDebugInfo.codexBinary)
                    self.binaryRow(title: L("claude_binary"), value: self.store.pathDebugInfo.claudeBinary)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("effective_path"))
                            .font(.callout.weight(.semibold))
                        ScrollView {
                            Text(
                                self.store.pathDebugInfo.effectivePATH.isEmpty
                                    ? L("unavailable")
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
                            Text(L("login_shell_path"))
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
            return self.isLoadingLog ? L("loading") : L("no_log_yet_fetch")
        }
        return self.logText
    }

    private func loadLog(_ provider: UsageProvider) {
        self.isLoadingLog = true
        Task {
            let text = await ProviderInteractionContext.$current.withValue(.userInitiated) {
                await ProviderRefreshContext.$current.withValue(.regular) {
                    await self.store.debugLog(for: provider)
                }
            }
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
                let text = await ProviderInteractionContext.$current.withValue(.userInitiated) {
                    await ProviderRefreshContext.$current.withValue(.regular) {
                        await self.store.debugLog(for: provider)
                    }
                }
                await MainActor.run { self.logText = text }
                self.isLoadingLog = false
            }
            _ = await ProviderInteractionContext.$current.withValue(.userInitiated) {
                await ProviderRefreshContext.$current.withValue(.regular) {
                    await self.store.dumpLog(toFileFor: provider)
                }
            }
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
            Text(value ?? L("not_found"))
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

        self.costCacheStatus = L("cleared")
    }

    private func clearCookieCache() {
        let cleared = CookieHeaderCache.clearAll()
        if cleared > 0 {
            self.cookieCacheStatus = "Cleared \(cleared) provider\(cleared == 1 ? "" : "s")."
        } else {
            self.cookieCacheStatus = "No cached cookies found."
        }
    }

    private func fetchAttemptsText(for provider: UsageProvider) -> String {
        let attempts = self.store.fetchAttempts(for: provider)
        guard !attempts.isEmpty else { return L("no_fetch_attempts") }
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
