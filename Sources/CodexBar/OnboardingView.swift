import AppKit
import CodexBarCore
import SwiftUI

@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let store: UsageStore
    private let onFinish: @MainActor () -> Void
    private let onCancel: @MainActor () -> Void
    private var didComplete = false

    init(
        settings: SettingsStore,
        store: UsageStore,
        requestNotifications: @escaping @MainActor () async -> Bool,
        onFinish: @escaping @MainActor () -> Void,
        onCancel: @escaping @MainActor () -> Void)
    {
        self.store = store
        self.onFinish = onFinish
        self.onCancel = onCancel
        super.init(window: nil)

        let view = OnboardingView(
            settings: settings,
            requestNotifications: requestNotifications,
            onFinish: { [weak self] in
                self?.complete()
            })
        let hostingView = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 670),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = L("onboarding_window_title")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = .black
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.delegate = self
        window.center()
        self.window = window
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        self.window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        _ = notification
        guard !self.didComplete else { return }
        self.onCancel()
    }

    private func complete() {
        self.didComplete = true
        self.store.startBackgroundWorkAfterOnboarding()
        self.close()
        self.onFinish()
    }
}

@MainActor
struct OnboardingView: View {
    fileprivate enum Step: Int, CaseIterable {
        case welcome
        case detecting
        case providers
        case menuBar
        case settings

        var title: String {
            switch self {
            case .welcome: L("onboarding_step_welcome")
            case .detecting: L("onboarding_step_detecting")
            case .providers: L("onboarding_step_providers")
            case .menuBar: L("onboarding_step_menu_bar")
            case .settings: L("onboarding_step_settings")
            }
        }

        var iconName: String {
            switch self {
            case .welcome: "gauge.medium"
            case .detecting: "magnifyingglass"
            case .providers: "square.grid.2x2"
            case .menuBar: "menubar.rectangle"
            case .settings: "gearshape"
            }
        }
    }

    @Bindable var settings: SettingsStore
    let requestNotifications: @MainActor () async -> Bool
    let onFinish: @MainActor () -> Void
    @State private var step: Step = .welcome
    @State private var detectionResult = ProviderAccessDetectionResult(accesses: [])
    @State private var selectedProviders: Set<UsageProvider> = []
    @State private var notificationResult: Bool?
    @State private var isWorking = false
    @State private var displayPreferences = OnboardingDisplayPreferences.defaults
    @State private var didSeedDisplayPreferences = false
    @State private var finalPreferences = OnboardingFinalPreferences.firstRunDefaults
    @State private var detectionRunToken = 0
    @State private var revealedAccessLogCount = 0

    private var availableAccesses: [ProviderAccessDetection] {
        self.detectionResult.accesses.filter(\.isSelectable)
    }

    var body: some View {
        ZStack {
            OnboardingBackdrop()

            VStack(spacing: 0) {
                OnboardingTopProgress(currentStep: self.step)
                    .padding(.top, 22)
                    .frame(height: 62, alignment: .top)

                self.content

                if self.step != .welcome {
                    self.footer
                }
            }
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .frame(width: 980, height: 670)
        .onDisappear {
            self.detectionRunToken &+= 1
        }
    }

    private var content: some View {
        Group {
            switch self.step {
            case .welcome:
                self.welcomeContent
            case .detecting:
                self.detectingContent
            case .providers:
                self.providersContent
            case .menuBar:
                self.menuBarContent
            case .settings:
                self.settingsContent
            }
        }
        .padding(.horizontal, 58)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var welcomeContent: some View {
        VStack(spacing: 0) {
            OnboardingProviderIconStack()
                .padding(.bottom, 32)

            OnboardingWelcomeHeroHeader(
                subtitle: L("onboarding_welcome_subtitle"))
                .padding(.bottom, 36)

            Button {
                Task { await self.grantPermissionsAndDetect() }
            } label: {
                HStack(spacing: 8) {
                    Text(L("onboarding_permissions_grant"))
                    Image(systemName: "return")
                }
            }
            .buttonStyle(OnboardingActionButtonStyle(kind: .permission))
            .keyboardShortcut(.defaultAction)
            .disabled(self.isWorking)
        }
        .offset(y: -60)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var settingsContent: some View {
        OnboardingSplitContent(
            badge: L("onboarding_step_settings"),
            title: L("onboarding_settings_title"),
            subtitle: L("onboarding_settings_subtitle"))
        {
            OnboardingAccessList {
                OnboardingSettingsToggleRow(
                    systemImage: "bell.badge",
                    title: L("onboarding_notifications_low_quota_title"),
                    detail: L("onboarding_notifications_low_quota_detail"),
                    isOn: self.$finalPreferences.quotaAlertsEnabled)
                OnboardingSettingsToggleRow(
                    systemImage: "checkmark.seal",
                    title: L("onboarding_notifications_provider_status_title"),
                    detail: L("onboarding_notifications_provider_status_detail"),
                    isOn: self.$finalPreferences.providerStatusEnabled)
                OnboardingSettingsToggleRow(
                    systemImage: "power",
                    title: L("onboarding_notifications_permission_title"),
                    detail: L("onboarding_notifications_permission_detail"),
                    isOn: self.$finalPreferences.openAtLogin)
            }
        }
    }

    private var detectingContent: some View {
        HStack(alignment: .center, spacing: 28) {
            OnboardingTerminalScanPanel(visibleCount: self.revealedAccessLogCount)
                .frame(width: 540, height: 364)

            OnboardingAccessCopyPanel(visibleCount: self.revealedAccessLogCount)
                .frame(width: 280, height: 364)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var providersContent: some View {
        OnboardingSplitContent(
            badge: self.providerCountText,
            title: L("onboarding_providers_title"),
            subtitle: L("onboarding_providers_subtitle"))
        {
            OnboardingAccessList {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 8) {
                        ForEach(Array(self.availableAccesses.enumerated()), id: \.offset) { index, access in
                            OnboardingProviderAccessRow(
                                access: access,
                                index: index,
                                isSelected: self.binding(for: access.provider))
                        }

                        if self.selectedProviders.isEmpty {
                            OnboardingProviderSelectionHint()
                        }
                    }
                }
                .frame(maxHeight: 344)
            }
        }
    }

    private var menuBarContent: some View {
        HStack(alignment: .center, spacing: 44) {
            VStack(alignment: .leading, spacing: 18) {
                Text(L("onboarding_step_menu_bar"))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(OnboardingPalette.brandBlue)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(OnboardingPalette.brandBlue.opacity(0.14))
                    .clipShape(Capsule())

                VStack(alignment: .leading, spacing: 10) {
                    Text(L("onboarding_menu_bar_title"))
                        .font(.system(size: 38, weight: .semibold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L("onboarding_menu_bar_subtitle"))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(OnboardingPalette.secondaryText)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                OnboardingMenuBarControls(preferences: self.$displayPreferences)
            }
            .frame(width: 388, alignment: .leading)

            OnboardingMenuBarLivePreview(
                preferences: self.displayPreferences,
                providers: self.selectedProvidersForPreview)
                .scaleEffect(0.82)
                .frame(width: 430, height: 470)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            self.seedDisplayPreferencesIfNeeded()
        }
    }

    private var providerCountText: String {
        let detectedCount = self.detectionResult.accesses.count(where: { $0.state == .detected })
        if detectedCount == 0, self.availableAccesses.count == 1 {
            return L("onboarding_providers_default_count_one")
        }
        if detectedCount == 1 {
            return L("onboarding_providers_found_count_one")
        }
        return String(format: L("onboarding_providers_found_count_format"), detectedCount)
    }

    private var selectedProvidersForPreview: [UsageProvider] {
        let selected = self.availableAccesses
            .map(\.provider)
            .filter { self.selectedProviders.contains($0) }
        if !selected.isEmpty { return Array(selected.prefix(4)) }
        return [.codex, .claude, .gemini]
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button {
                self.goBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(OnboardingIconButtonStyle())
            .accessibilityLabel(L("onboarding_back"))
            .opacity(self.canGoBack ? 1 : 0)
            .disabled(!self.canGoBack || self.isWorking)

            Spacer()

            if self.step == .menuBar {
                Button {
                    self.displayPreferences = .defaults
                    self.step = .settings
                } label: {
                    HStack(spacing: 7) {
                        Text(L("onboarding_menu_bar_defaults"))
                        HStack(spacing: 2) {
                            Text("⌘")
                                .font(.system(size: 12, weight: .bold))
                            Image(systemName: "return")
                                .font(.system(size: 11, weight: .bold))
                        }
                        .foregroundStyle(Color.white.opacity(0.46))
                    }
                }
                .buttonStyle(OnboardingActionButtonStyle(kind: .secondary))
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(self.isWorking)
            }

            self.primaryButton
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        .frame(height: 74)
        .background(alignment: .bottom) {
            LinearGradient(
                colors: [
                    Color.black.opacity(0),
                    Color.black.opacity(0.42),
                    Color.black.opacity(0.7),
                ],
                startPoint: .top,
                endPoint: .bottom)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        if self.step == .providers {
            Button {
                self.step = .menuBar
            } label: {
                HStack(spacing: 8) {
                    Text(L("continue"))
                    Image(systemName: "return")
                }
            }
            .buttonStyle(OnboardingActionButtonStyle(kind: .primary))
            .keyboardShortcut(.defaultAction)
            .disabled(self.selectedProviders.isEmpty)
        } else if self.step == .menuBar {
            Button {
                self.step = .settings
            } label: {
                HStack(spacing: 8) {
                    Text(L("continue"))
                    Image(systemName: "return")
                }
            }
            .buttonStyle(OnboardingActionButtonStyle(kind: .primary))
            .keyboardShortcut(.defaultAction)
            .disabled(self.isWorking)
        } else if self.step == .settings {
            Button {
                self.finish(displayPreferences: self.displayPreferences, finalPreferences: self.finalPreferences)
            } label: {
                HStack(spacing: 8) {
                    Text(L("onboarding_finish"))
                    Image(systemName: "return")
                }
            }
            .buttonStyle(OnboardingActionButtonStyle(kind: .finish))
            .keyboardShortcut(.defaultAction)
            .disabled(self.isWorking)
        }
    }

    private var canGoBack: Bool {
        self.step != .welcome && self.step != .detecting
    }

    private func goBack() {
        switch self.step {
        case .welcome, .detecting:
            break
        case .providers:
            self.step = .welcome
        case .menuBar:
            self.step = .providers
        case .settings:
            self.step = .menuBar
        }
    }

    private func binding(for provider: UsageProvider) -> Binding<Bool> {
        Binding(
            get: { self.selectedProviders.contains(provider) },
            set: { isSelected in
                if isSelected {
                    self.selectedProviders.insert(provider)
                } else {
                    self.selectedProviders.remove(provider)
                }
            })
    }

    private func grantPermissionsAndDetect() async {
        guard !self.isWorking else { return }
        self.isWorking = true
        self.settings.notificationPermissionPromptHandled = true
        NSApp.activate(ignoringOtherApps: true)
        self.notificationResult = await self.requestNotifications()
        self.isWorking = false
        await self.runDetection()
    }

    private func runDetection() async {
        self.detectionRunToken &+= 1
        let runToken = self.detectionRunToken
        self.step = .detecting
        self.isWorking = true
        let detectionTask = Task { @MainActor in
            await self.settings.detectProviderAccesses()
        }
        await self.runAccessLogAnimation()
        let result = await detectionTask.value
        guard runToken == self.detectionRunToken else { return }
        try? await Task.sleep(nanoseconds: 320_000_000)
        let displayResult = self.resultWithPreviewMockAccesses(result)
        self.detectionResult = displayResult
        self.selectedProviders = Set(displayResult.suggestedProviders)
        self.isWorking = false
        self.step = .providers
    }

    private func runAccessLogAnimation() async {
        self.revealedAccessLogCount = 0
        for count in 1...OnboardingAccessLogList.itemCount {
            self.revealedAccessLogCount = count
            try? await Task.sleep(nanoseconds: 560_000_000)
        }
        self.revealedAccessLogCount = OnboardingAccessLogList.itemCount + 1
    }

    private func resultWithPreviewMockAccesses(_ result: ProviderAccessDetectionResult)
    -> ProviderAccessDetectionResult {
        #if DEBUG
        guard Bundle.main.bundleIdentifier?.contains("onboarding-preview") == true else { return result }
        let mocks = [
            ProviderAccessDetection(
                provider: .codex,
                state: .detected,
                detail: L("onboarding_provider_preview_codex_detail")),
            ProviderAccessDetection(
                provider: .cursor,
                state: .detected,
                detail: L("onboarding_provider_preview_cursor_detail")),
            ProviderAccessDetection(
                provider: .opencode,
                state: .detected,
                detail: L("onboarding_provider_preview_opencode_detail")),
        ]
        var byProvider = Dictionary(uniqueKeysWithValues: result.accesses.map { ($0.provider, $0) })
        for mock in mocks {
            byProvider[mock.provider] = mock
        }
        let preferredOrder: [UsageProvider] = [.codex, .cursor, .opencode, .antigravity, .openai, .claude, .gemini]
        let remaining = result.accesses.map(\.provider).filter { !preferredOrder.contains($0) }
        return ProviderAccessDetectionResult(accesses: (preferredOrder + remaining).compactMap { byProvider[$0] })
        #else
        return result
        #endif
    }

    private func seedDisplayPreferencesIfNeeded() {
        guard !self.didSeedDisplayPreferences else { return }
        self.displayPreferences = OnboardingDisplayPreferences(settings: self.settings)
        self.didSeedDisplayPreferences = true
    }

    private func finish(
        displayPreferences: OnboardingDisplayPreferences,
        finalPreferences: OnboardingFinalPreferences)
    {
        self.apply(displayPreferences: displayPreferences)
        self.apply(finalPreferences: finalPreferences)
        self.settings.completeOnboarding(
            detectionResult: self.detectionResult,
            selectedProviders: self.selectedProviders)
        self.onFinish()
    }

    private func apply(displayPreferences: OnboardingDisplayPreferences) {
        self.settings.mergeIcons = displayPreferences.mergeIcons
        self.settings.switcherShowsIcons = displayPreferences.mergeIcons && displayPreferences.switcherShowsIcons
        self.settings.menuBarShowsHighestUsage = displayPreferences.mergeIcons && displayPreferences
            .menuBarShowsHighestUsage
        self.settings.menuBarShowsBrandIconWithPercent = displayPreferences.menuBarShowsBrandIconWithPercent
        self.settings.menuBarDisplayMode = displayPreferences.menuBarDisplayMode
        self.settings.showOptionalCreditsAndExtraUsage = displayPreferences.showOptionalCreditsAndExtraUsage
    }

    private func apply(finalPreferences: OnboardingFinalPreferences) {
        self.settings.sessionQuotaNotificationsEnabled = finalPreferences.quotaAlertsEnabled
        self.settings.quotaWarningNotificationsEnabled = finalPreferences.quotaAlertsEnabled
        self.settings.statusChecksEnabled = finalPreferences.providerStatusEnabled
        self.settings.launchAtLogin = finalPreferences.openAtLogin
    }
}

enum OnboardingPalette {
    static let accent = Color(red: 1.0, green: 0.24, blue: 0.62)
    static let brandBlue = Color(red: 0.07, green: 0.50, blue: 1.0)
    static let codexTeal = Color(red: 0.35, green: 0.78, blue: 0.84)
    static let blue = Color(red: 0.36, green: 0.43, blue: 1.0)
    static let purple = Color(red: 0.62, green: 0.30, blue: 1.0)
    static let surface = Color.white.opacity(0.058)
    static let border = Color.white.opacity(0.12)
    static let secondaryText = Color.white.opacity(0.52)
    static let success = Color(red: 0.3, green: 0.9, blue: 0.72)

    static var brandGradient: LinearGradient {
        LinearGradient(
            colors: [accent, purple, blue],
            startPoint: .leading,
            endPoint: .trailing)
    }

    static var controlGradient: LinearGradient {
        LinearGradient(
            colors: [brandBlue, blue, purple],
            startPoint: .leading,
            endPoint: .trailing)
    }

    static var finishGradient: LinearGradient {
        LinearGradient(
            colors: [purple.opacity(0.85), blue, brandBlue],
            startPoint: .leading,
            endPoint: .trailing)
    }

    static var subtleBrandGradient: LinearGradient {
        LinearGradient(
            colors: [
                brandBlue.opacity(0.16),
                purple.opacity(0.12),
                blue.opacity(0.18),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing)
    }
}

struct OnboardingDisplayPreferences: Equatable {
    var mergeIcons: Bool
    var switcherShowsIcons: Bool
    var menuBarShowsHighestUsage: Bool
    var menuBarShowsBrandIconWithPercent: Bool
    var menuBarDisplayMode: MenuBarDisplayMode
    var showOptionalCreditsAndExtraUsage: Bool

    static let defaults = OnboardingDisplayPreferences(
        mergeIcons: true,
        switcherShowsIcons: true,
        menuBarShowsHighestUsage: false,
        menuBarShowsBrandIconWithPercent: false,
        menuBarDisplayMode: .percent,
        showOptionalCreditsAndExtraUsage: true)

    init(
        mergeIcons: Bool,
        switcherShowsIcons: Bool,
        menuBarShowsHighestUsage: Bool,
        menuBarShowsBrandIconWithPercent: Bool,
        menuBarDisplayMode: MenuBarDisplayMode,
        showOptionalCreditsAndExtraUsage: Bool)
    {
        self.mergeIcons = mergeIcons
        self.switcherShowsIcons = switcherShowsIcons
        self.menuBarShowsHighestUsage = menuBarShowsHighestUsage
        self.menuBarShowsBrandIconWithPercent = menuBarShowsBrandIconWithPercent
        self.menuBarDisplayMode = menuBarDisplayMode
        self.showOptionalCreditsAndExtraUsage = showOptionalCreditsAndExtraUsage
    }

    @MainActor
    init(settings: SettingsStore) {
        self.init(
            mergeIcons: settings.mergeIcons,
            switcherShowsIcons: settings.switcherShowsIcons,
            menuBarShowsHighestUsage: settings.menuBarShowsHighestUsage,
            menuBarShowsBrandIconWithPercent: settings.menuBarShowsBrandIconWithPercent,
            menuBarDisplayMode: settings.menuBarDisplayMode,
            showOptionalCreditsAndExtraUsage: settings.showOptionalCreditsAndExtraUsage)
    }
}

private struct OnboardingFinalPreferences: Equatable {
    var quotaAlertsEnabled: Bool
    var providerStatusEnabled: Bool
    var openAtLogin: Bool

    static let firstRunDefaults = OnboardingFinalPreferences(
        quotaAlertsEnabled: true,
        providerStatusEnabled: true,
        openAtLogin: true)
}

private struct OnboardingBackdrop: View {
    var body: some View {
        ZStack {
            Color(red: 0.012, green: 0.013, blue: 0.018)
            RadialGradient(
                colors: [
                    OnboardingPalette.brandBlue.opacity(0.24),
                    OnboardingPalette.blue.opacity(0.08),
                    Color.clear,
                ],
                center: .topLeading,
                startRadius: 18,
                endRadius: 560)
            OnboardingTopGrid()
            RadialGradient(
                colors: [
                    OnboardingPalette.blue.opacity(0.24),
                    OnboardingPalette.purple.opacity(0.08),
                    Color.clear,
                ],
                center: .bottomTrailing,
                startRadius: 40,
                endRadius: 520)
            LinearGradient(
                colors: [
                    Color.black.opacity(0.1),
                    Color.black.opacity(0.62),
                    Color.black.opacity(0.24),
                ],
                startPoint: .top,
                endPoint: .bottom)
            LinearGradient(
                colors: [
                    Color.clear,
                    Color.white.opacity(0.025),
                    Color.clear,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing)
                .blur(radius: 30)

            ForEach(0..<4, id: \.self) { index in
                Capsule()
                    .fill(Color.white.opacity(0.018))
                    .frame(width: 360, height: 1)
                    .rotationEffect(.degrees(-11))
                    .offset(x: CGFloat(index) * 170 - 260, y: CGFloat(index) * 70 - 110)
            }
        }
        .ignoresSafeArea()
    }
}

private struct OnboardingTopGrid: View {
    private let spacing: CGFloat = 44

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                var path = Path()
                var x: CGFloat = 0
                while x <= size.width {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    x += self.spacing
                }

                var y: CGFloat = 0
                while y <= size.height {
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    y += self.spacing
                }

                context.stroke(path, with: .color(.white.opacity(0.035)), lineWidth: 1)
            }
            .frame(width: proxy.size.width, height: 250)
            .mask {
                LinearGradient(
                    colors: [.white.opacity(0.72), .white.opacity(0.24), .clear],
                    startPoint: .top,
                    endPoint: .bottom)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct OnboardingProviderIconStack: View {
    private struct StackIcon: Identifiable {
        enum Kind: String {
            case app
            case provider
        }

        let id: String
        let kind: Kind
        let provider: UsageProvider?
        let offset: CGSize
        let size: CGFloat
        let rotation: Double
        let opacity: Double
        let zIndex: Double

        var isCenter: Bool {
            self.kind == .app
        }
    }

    private let icons: [StackIcon] = [
        StackIcon(
            id: "claude",
            kind: .provider,
            provider: .claude,
            offset: CGSize(width: -118, height: 24),
            size: 44,
            rotation: -8,
            opacity: 0.68,
            zIndex: 1),
        StackIcon(
            id: "codex",
            kind: .provider,
            provider: .codex,
            offset: CGSize(width: -62, height: 8),
            size: 56,
            rotation: -4,
            opacity: 0.88,
            zIndex: 3),
        StackIcon(
            id: "codexbar",
            kind: .app,
            provider: nil,
            offset: CGSize(width: 0, height: -12),
            size: 72,
            rotation: 0,
            opacity: 1,
            zIndex: 10),
        StackIcon(
            id: "cursor",
            kind: .provider,
            provider: .cursor,
            offset: CGSize(width: 62, height: 8),
            size: 56,
            rotation: 4,
            opacity: 0.88,
            zIndex: 3),
        StackIcon(
            id: "opencode",
            kind: .provider,
            provider: .opencode,
            offset: CGSize(width: 118, height: 24),
            size: 44,
            rotation: 8,
            opacity: 0.68,
            zIndex: 1),
    ]

    var body: some View {
        ZStack {
            ForEach(self.icons.filter { !$0.isCenter }) { icon in
                self.connection(to: icon)
                    .zIndex(0)
            }

            ForEach(self.icons) { icon in
                self.mark(for: icon)
                    .shadow(
                        color: self.color(for: icon).opacity(icon.isCenter ? 0.16 : 0.08),
                        radius: icon.isCenter ? 16 : 10,
                        y: icon.isCenter ? 9 : 6)
                    .opacity(icon.opacity)
                    .rotationEffect(.degrees(icon.rotation))
                    .offset(icon.offset)
                    .zIndex(icon.zIndex)
            }
        }
        .frame(width: 330, height: 138)
    }

    @ViewBuilder
    private func mark(for icon: StackIcon) -> some View {
        if icon.isCenter {
            OnboardingCodexBarAppIcon(size: icon.size)
        } else if let provider = icon.provider {
            OnboardingProviderMiniIcon(provider: provider, size: icon.size)
        }
    }

    private func connection(to icon: StackIcon) -> some View {
        let start = CGSize(width: 0, height: -12)
        let dx = icon.offset.width - start.width
        let dy = icon.offset.height - start.height
        let length = max(1, sqrt(dx * dx + dy * dy) - (icon.size * 0.74))
        let angle = Angle(radians: atan2(dy, dx))

        return Capsule()
            .fill(
                LinearGradient(
                    colors: [
                        OnboardingPalette.brandBlue.opacity(0.20),
                        Color.white.opacity(0.08),
                        Color.clear,
                    ],
                    startPoint: .leading,
                    endPoint: .trailing))
            .frame(width: length, height: 1)
            .rotationEffect(angle)
            .offset(x: start.width + dx / 2, y: start.height + dy / 2)
            .opacity(icon.opacity * 0.78)
    }

    private func color(for icon: StackIcon) -> Color {
        if icon.isCenter {
            return OnboardingPalette.brandBlue
        }
        guard let provider = icon.provider else { return Color.white.opacity(0.12) }
        return ProviderDescriptorRegistry.descriptor(for: provider).branding.color.swiftUIColor
    }
}

private struct OnboardingWelcomeHeroHeader: View {
    let subtitle: String

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Text("Every AI coding limit,")
                    .foregroundStyle(.white)
                Text("in your menu bar.")
                    .foregroundStyle(OnboardingPalette.brandGradient)
            }
            .font(.system(size: 37, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.74)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 850)

            Text(self.subtitle)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(OnboardingPalette.secondaryText)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 580)
        }
    }
}

private struct OnboardingHeroHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 10) {
            Text(self.title)
                .font(.system(size: 37, weight: .semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(self.subtitle)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(OnboardingPalette.secondaryText)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 580)
        }
    }
}

private struct OnboardingSplitContent<RightContent: View>: View {
    let badge: String
    let title: String
    let subtitle: String
    @ViewBuilder let rightContent: () -> RightContent

    var body: some View {
        HStack(alignment: .center, spacing: 74) {
            VStack(alignment: .leading, spacing: 14) {
                Text(self.badge)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(OnboardingPalette.brandBlue)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(OnboardingPalette.brandBlue.opacity(0.14))
                    .clipShape(Capsule())
                Text(self.title)
                    .font(.system(size: 40, weight: .semibold))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text(self.subtitle)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(OnboardingPalette.secondaryText)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 300, alignment: .leading)
            }
            .frame(width: 300, alignment: .leading)

            self.rightContent()
                .frame(width: 470)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct OnboardingFeatureItem: Identifiable {
    let systemImage: String
    let title: String

    var id: String {
        self.title
    }
}

private struct OnboardingFeatureList: View {
    let items: [OnboardingFeatureItem]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(self.items) { item in
                VStack(spacing: 8) {
                    Image(systemName: item.systemImage)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(OnboardingPalette.brandBlue)
                        .frame(width: 32, height: 32)
                        .background(OnboardingPalette.brandBlue.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Text(item.title)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.84))
                        .lineLimit(1)
                        .minimumScaleFactor(0.84)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
        }
        .padding(.horizontal, 10)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.03))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        }
    }
}

private struct OnboardingAccessList<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 8) {
            self.content()
        }
        .padding(6)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.thinMaterial)
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.025))
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.22), radius: 24, y: 18)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct OnboardingInfoRow: View {
    enum StatusStyle {
        case neutral
        case success
    }

    let systemImage: String
    let title: String
    let detail: String
    var status: String?
    var statusStyle: StatusStyle = .neutral

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: self.systemImage)
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(OnboardingPalette.brandBlue)
                .frame(width: 44, height: 44)
                .background(OnboardingPalette.brandBlue.opacity(0.11))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(self.title)
                    .font(.callout.weight(.semibold))
                Text(self.detail)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(OnboardingPalette.secondaryText)
                    .lineLimit(2)
            }

            Spacer()

            if let status {
                Text(status)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(self.statusColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(self.statusColor.opacity(0.12))
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
    }

    private var statusColor: Color {
        switch self.statusStyle {
        case .neutral:
            OnboardingPalette.secondaryText
        case .success:
            OnboardingPalette.success
        }
    }
}

private struct OnboardingSettingsToggleRow: View {
    let systemImage: String
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: self.systemImage)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(OnboardingPalette.brandBlue)
                .frame(width: 42, height: 42)
                .background(Color.white.opacity(0.045))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(self.title)
                    .font(.callout.weight(.semibold))
                Text(self.detail)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(OnboardingPalette.secondaryText)
                    .lineLimit(2)
            }

            Spacer()

            Toggle("", isOn: self.$isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(self.isOn ? Color.white.opacity(0.040) : Color.white.opacity(0.018))
        }
    }
}

private struct OnboardingProviderAccessRow: View {
    let access: ProviderAccessDetection
    let index: Int
    @Binding var isSelected: Bool
    @State private var isHovered = false
    @State private var hasAppeared = false

    var body: some View {
        Button {
            self.isSelected.toggle()
        } label: {
            HStack(alignment: .center, spacing: 14) {
                self.icon

                VStack(alignment: .leading, spacing: 4) {
                    Text(self.displayName)
                        .font(.callout.weight(.semibold))
                    Text(self.access.detail)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(OnboardingPalette.secondaryText)
                        .lineLimit(2)
                }

                Spacer()

                Image(systemName: self.isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(self.isSelected ? OnboardingPalette.success : Color.white.opacity(0.24))
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(self.rowFill)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(self.rowStroke, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .onHover { self.isHovered = $0 }
        .opacity(self.hasAppeared ? 1 : 0)
        .offset(y: self.hasAppeared ? 0 : 10)
        .animation(.snappy(duration: 0.28).delay(Double(self.index) * 0.045), value: self.hasAppeared)
        .onAppear { self.hasAppeared = true }
    }

    @ViewBuilder
    private var icon: some View {
        if let image = ProviderBrandIcon.image(for: self.access.provider) {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .foregroundStyle(.white.opacity(0.95))
                .padding(9)
                .frame(width: 42, height: 42)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(self.accent)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            Image(systemName: "terminal")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 42, height: 42)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var displayName: String {
        ProviderDescriptorRegistry.metadata[self.access.provider]?.displayName ?? self.access.provider.rawValue
    }

    private var accent: Color {
        ProviderDescriptorRegistry.descriptor(for: self.access.provider).branding.color.swiftUIColor
    }

    private var rowFill: AnyShapeStyle {
        if self.isSelected {
            return AnyShapeStyle(.regularMaterial)
        }
        if self.isHovered {
            return AnyShapeStyle(Color.white.opacity(0.07))
        }
        return AnyShapeStyle(Color.white.opacity(0.018))
    }

    private var rowStroke: Color {
        if self.isSelected {
            return Color.white.opacity(0.22)
        }
        if self.isHovered {
            return Color.white.opacity(0.13)
        }
        return Color.white.opacity(0.055)
    }
}

private struct OnboardingMissingAccessSummary: View {
    let accesses: [ProviderAccessDetection]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(OnboardingPalette.secondaryText)
            Text(String(format: L("onboarding_provider_missing_summary_format"), self.names))
                .font(.footnote.weight(.medium))
                .foregroundStyle(OnboardingPalette.secondaryText)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }

    private var names: String {
        self.accesses
            .map { ProviderDescriptorRegistry.metadata[$0.provider]?.displayName ?? $0.provider.rawValue }
            .joined(separator: ", ")
    }
}

private struct OnboardingProviderSelectionHint: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
            Text(L("onboarding_providers_select_one"))
            Spacer()
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(OnboardingPalette.secondaryText)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct OnboardingTopProgress: View {
    let currentStep: OnboardingView.Step

    var body: some View {
        HStack(spacing: 10) {
            ForEach(OnboardingView.Step.allCases, id: \.self) { step in
                HStack(spacing: 10) {
                    OnboardingStepToken(
                        step: step,
                        state: self.state(for: step))
                    if step != OnboardingView.Step.allCases.last {
                        Rectangle()
                            .fill(Color.white.opacity(step.rawValue < self.currentStep.rawValue ? 0.18 : 0.07))
                            .frame(width: 20, height: 1)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .animation(.snappy(duration: 0.2), value: self.currentStep)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(self.currentStep.title)
    }

    private func state(for step: OnboardingView.Step) -> OnboardingStepToken.State {
        if step.rawValue < self.currentStep.rawValue { return .completed }
        if step == self.currentStep { return .current }
        return .upcoming
    }
}

private struct OnboardingStepToken: View {
    enum State {
        case completed
        case current
        case upcoming
    }

    let step: OnboardingView.Step
    let state: State

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: self.iconName)
                .font(.system(size: 11, weight: .semibold))
            Text(self.step.title)
                .font(.system(size: 11, weight: .bold))
        }
        .foregroundStyle(self.foreground)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background {
            Capsule()
                .fill(self.background)
        }
        .overlay {
            Capsule()
                .stroke(self.stroke, lineWidth: 1)
        }
    }

    private var iconName: String {
        switch self.state {
        case .completed:
            "checkmark"
        case .current, .upcoming:
            self.step.iconName
        }
    }

    private var foreground: Color {
        switch self.state {
        case .completed:
            Color.white.opacity(0.68)
        case .current:
            .white
        case .upcoming:
            Color.white.opacity(0.34)
        }
    }

    private var background: Color {
        switch self.state {
        case .completed:
            Color.white.opacity(0.035)
        case .current:
            OnboardingPalette.brandBlue.opacity(0.14)
        case .upcoming:
            Color.clear
        }
    }

    private var stroke: Color {
        switch self.state {
        case .completed:
            Color.white.opacity(0.055)
        case .current:
            OnboardingPalette.brandBlue.opacity(0.22)
        case .upcoming:
            Color.white.opacity(0)
        }
    }
}

private struct OnboardingMenuBarControls: View {
    @Binding var preferences: OnboardingDisplayPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            OnboardingMenuBarControlSection(title: L("onboarding_menu_bar_layout")) {
                Picker("", selection: self.layoutSelection) {
                    Text(L("onboarding_menu_bar_layout_merged")).tag(true)
                    Text(L("onboarding_menu_bar_layout_separate")).tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            OnboardingMenuBarControlSection(title: L("onboarding_menu_bar_item_section")) {
                OnboardingToggleRow(
                    title: L("onboarding_menu_bar_brand_percent"),
                    isOn: self.$preferences.menuBarShowsBrandIconWithPercent)

                if self.preferences.menuBarShowsBrandIconWithPercent {
                    Picker("", selection: self.$preferences.menuBarDisplayMode) {
                        ForEach(MenuBarDisplayMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if self.preferences.mergeIcons {
                    OnboardingToggleRow(
                        title: L("onboarding_menu_bar_highest_usage"),
                        isOn: self.$preferences.menuBarShowsHighestUsage)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            OnboardingMenuBarControlSection(title: L("onboarding_menu_bar_sections_section")) {
                OnboardingToggleRow(
                    title: L("onboarding_menu_bar_credits_section"),
                    isOn: self.$preferences.showOptionalCreditsAndExtraUsage)
            }

            if self.preferences.mergeIcons {
                OnboardingMenuBarControlSection(title: L("onboarding_menu_bar_switcher_section")) {
                    OnboardingToggleRow(
                        title: L("onboarding_menu_bar_switcher_icons"),
                        isOn: self.$preferences.switcherShowsIcons)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.04))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        }
        .animation(.snappy(duration: 0.2), value: self.preferences.mergeIcons)
    }

    private var layoutSelection: Binding<Bool> {
        Binding(
            get: { self.preferences.mergeIcons },
            set: { self.preferences.mergeIcons = $0 })
    }
}

private struct OnboardingToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(self.title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white.opacity(0.86))
                .lineLimit(1)
                .minimumScaleFactor(0.84)
            Spacer(minLength: 10)
            Toggle("", isOn: self.$isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .frame(width: 54, alignment: .trailing)
        }
        .frame(height: 28)
    }
}

private struct OnboardingMenuBarControlSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(self.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(OnboardingPalette.secondaryText)
            self.content()
        }
    }
}
