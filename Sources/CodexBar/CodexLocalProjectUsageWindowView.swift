import AppKit
import CodexBarCore
import SwiftUI

enum CodexLocalProjectUsageWindowLayout {
    static let idealSize = NSSize(width: 1380, height: 780)
    static let minimumSize = NSSize(width: 980, height: 640)
    static let sidebarMinimumWidth: CGFloat = 236
    static let sidebarIdealWidth: CGFloat = 278
    static let sidebarMaximumWidth: CGFloat = 336
    static let commandHeight: CGFloat = 44
    static let footerHeight: CGFloat = 18
    static let detailPadding: CGFloat = 20
    static let sectionSpacing: CGFloat = 16
    static let cardRadius: CGFloat = 11
}

enum CodexLocalProjectUsageWindowTab: String, CaseIterable, Identifiable {
    case overview
    case sessions
    case models

    var id: String {
        self.rawValue
    }

    var title: String {
        switch self {
        case .overview: L("codex_workspaces_overview")
        case .sessions: L("codex_workspaces_sessions")
        case .models: L("codex_workspaces_models")
        }
    }
}

@MainActor
struct CodexLocalProjectUsageWindowView: View {
    let store: UsageStore
    let settings: SettingsStore
    @Bindable var selection: CodexLocalProjectUsageInspectorSelection

    @AppStorage(CodexLocalProjectUsageWindowController.selectedTabKey)
    private var selectedTabRaw = CodexLocalProjectUsageWindowTab.overview.rawValue
    @State private var customHistoryDays = 60
    @State private var associatedSessionIDs: Set<String>?
    @Environment(\.colorScheme) private var colorScheme

    private var selectedTab: CodexLocalProjectUsageWindowTab {
        get { CodexLocalProjectUsageWindowTab(rawValue: self.selectedTabRaw) ?? .overview }
        nonmutating set { self.selectedTabRaw = newValue.rawValue }
    }

    var body: some View {
        let appLanguage = self.settings.appLanguage
        self.windowContent
            .frame(
                minWidth: CodexLocalProjectUsageWindowLayout.minimumSize.width,
                idealWidth: CodexLocalProjectUsageWindowLayout.idealSize.width,
                maxWidth: .infinity,
                minHeight: CodexLocalProjectUsageWindowLayout.minimumSize.height,
                idealHeight: CodexLocalProjectUsageWindowLayout.idealSize.height,
                maxHeight: .infinity)
            .background {
                Color(nsColor: .windowBackgroundColor)
                SettingsWindowAppearanceBridge(
                    colorScheme: self.colorScheme,
                    windowTitle: L("codex_workspaces_window_title"))
                    .allowsHitTesting(false)
            }
            .background {
                CodexWorkspaceKeyboardCommands(
                    selectedTab: self.selectedTabBinding,
                    refresh: self.refresh)
            }
            .onAppear {
                self.customHistoryDays = self.settings.costUsageHistoryDays
                self.reconcileSelection()
            }
            .onChange(of: self.store.codexLocalProjectUsageSnapshot) {
                self.reconcileSelection()
            }
            .onChange(of: self.selection.selectedProjectID) { previousProjectID, selectedProjectID in
                self.associatedSessionIDs = CodexWorkspaceAssociatedSessionFilter.reconciledSessionIDs(
                    self.associatedSessionIDs,
                    from: previousProjectID,
                    to: selectedProjectID)
            }
            .environment(
                \.locale,
                appLanguage.isEmpty ? .autoupdatingCurrent : Locale(identifier: appLanguage))
    }

    @ViewBuilder
    private var windowContent: some View {
        if #available(macOS 26.0, *) {
            self.primaryContent
        } else {
            VStack(spacing: 0) {
                self.primaryContent
                Divider()
                CodexWorkspaceStatusBar(store: self.store)
                    .frame(height: CodexLocalProjectUsageWindowLayout.footerHeight)
            }
        }
    }

    @ViewBuilder
    private var primaryContent: some View {
        switch CodexWorkspacePrimaryContentState.resolve(
            snapshot: self.store.codexLocalProjectUsageSnapshot,
            isRefreshing: self.store.codexLocalProjectUsageRefreshInFlight)
        {
        case let .content(snapshot):
            let presentation = CodexLocalProjectUsageWindowPresentation(
                snapshot: snapshot,
                selectedDestinationID: self.selection.selectedProjectID,
                projection: self.store.codexLocalProjectUsageProjection)
            self.workspaceContent(presentation)
        case .indexing:
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.regular)
                Text(
                    self.store.codexLocalProjectUsageProgressSubtitle
                        ?? L("codex_workspaces_indexing_local_logs"))
                    .foregroundStyle(.secondary)
                if let fraction = self.store.codexLocalProjectUsageProgressFraction {
                    Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        case .empty:
            ContentUnavailableView(
                L("codex_workspaces_no_local_usage"),
                systemImage: "folder.badge.questionmark",
                description: Text(L("codex_workspaces_estimated_local_logs")))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func workspaceContent(_ presentation: CodexLocalProjectUsageWindowPresentation) -> some View {
        NavigationSplitView {
            CodexWorkspaceSidebar(
                presentation: presentation,
                showsEstimatedCost: self.settings.codexLocalProjectUsageShowsEstimatedCost,
                selectedDestinationID: self.$selection.selectedProjectID)
                .navigationSplitViewColumnWidth(
                    min: CodexLocalProjectUsageWindowLayout.sidebarMinimumWidth,
                    ideal: CodexLocalProjectUsageWindowLayout.sidebarIdealWidth,
                    max: CodexLocalProjectUsageWindowLayout.sidebarMaximumWidth)
        } detail: {
            CodexWorkspaceDetail(
                presentation: presentation,
                selectedTab: self.selectedTabBinding,
                showsEstimatedCost: self.settings.codexLocalProjectUsageShowsEstimatedCost,
                hidePersonalInfo: self.settings.hidePersonalInfo,
                historyDays: self.settings.costUsageHistoryDays,
                customHistoryDays: self.$customHistoryDays,
                isRefreshing: self.store.codexLocalProjectUsageRefreshInFlight,
                progressText: self.store.codexLocalProjectUsageProgressSubtitle,
                staleMessage: self.store.codexLocalProjectUsageLoadState == .stale
                    ? self.store.codexLocalProjectUsageError
                    : nil,
                associatedSessionIDs: self.$associatedSessionIDs,
                setHistoryDays: self.setHistoryDays,
                refresh: self.refresh)
            {
                CodexWorkspaceCommandBar(
                    selectedTab: self.selectedTabBinding,
                    historyDays: self.settings.costUsageHistoryDays,
                    customHistoryDays: self.$customHistoryDays,
                    isRefreshing: self.store.codexLocalProjectUsageRefreshInFlight,
                    setHistoryDays: self.setHistoryDays,
                    refresh: self.refresh)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                CodexWorkspaceSplitViewUnderlayBridge()
                    .frame(width: 0, height: 0)
            }
            .background {
                if #unavailable(macOS 26.0) {
                    Color(nsColor: .windowBackgroundColor)
                }
            }
            .modifier(CodexWorkspaceDetailFooter(store: self.store))
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var selectedTabBinding: Binding<CodexLocalProjectUsageWindowTab> {
        Binding(get: { self.selectedTab }, set: { self.selectedTab = $0 })
    }

    private func reconcileSelection() {
        guard let snapshot = self.store.codexLocalProjectUsageSnapshot else { return }
        let selectedID = self.selection.selectedProjectID
        let isValid = selectedID == CodexLocalProjectUsageWindowDestination.allWorkspacesID
            || snapshot.projects.contains { $0.id == selectedID }
        if !isValid {
            self.selection.selectedProjectID = CodexLocalProjectUsageWindowDestination.allWorkspacesID
        }
    }

    private func refresh() {
        self.store.scheduleCodexLocalProjectUsageRefreshIfNeeded(force: true)
    }

    private func setHistoryDays(_ days: Int) {
        let clamped = min(max(days, 1), 365)
        guard clamped != self.settings.costUsageHistoryDays else { return }
        self.settings.costUsageHistoryDays = clamped
        self.customHistoryDays = clamped
        self.refresh()
    }
}

@MainActor
private struct CodexWorkspaceDetailFooter: ViewModifier {
    let store: UsageStore

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .scrollEdgeEffectStyle(.soft, for: .bottom)
                .safeAreaBar(edge: .bottom, spacing: 0) {
                    CodexWorkspaceStatusBar(store: self.store)
                        .frame(height: CodexLocalProjectUsageWindowLayout.footerHeight)
                }
        } else {
            content
        }
    }
}

private struct CodexWorkspaceSplitViewUnderlayBridge: NSViewRepresentable {
    func makeNSView(context: Context) -> CodexWorkspaceSplitViewUnderlayConfigurationView {
        CodexWorkspaceSplitViewUnderlayConfigurationView()
    }

    func updateNSView(_ nsView: CodexWorkspaceSplitViewUnderlayConfigurationView, context: Context) {
        nsView.scheduleConfiguration()
    }
}

private final class CodexWorkspaceSplitViewUnderlayConfigurationView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        self.scheduleConfiguration()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        self.scheduleConfiguration()
    }

    func scheduleConfiguration() {
        guard #available(macOS 26.0, *) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.configureSplitViewItem()
        }
    }

    @available(macOS 26.0, *)
    private func configureSplitViewItem() {
        guard let splitViewController = self.enclosingSplitViewController(),
              let detailItem = splitViewController.splitViewItems.last,
              !detailItem.automaticallyAdjustsSafeAreaInsets
        else { return }
        detailItem.automaticallyAdjustsSafeAreaInsets = true
    }

    private func enclosingSplitViewController() -> NSSplitViewController? {
        var responder: NSResponder? = self
        while let currentResponder = responder {
            if let viewController = currentResponder as? NSViewController,
               let splitViewController = Self.enclosingSplitViewController(from: viewController)
            {
                return splitViewController
            }
            responder = currentResponder.nextResponder
        }

        guard let rootViewController = self.window?.contentViewController else { return nil }
        return Self.firstSplitViewController(in: rootViewController)
    }

    private static func enclosingSplitViewController(from viewController: NSViewController)
        -> NSSplitViewController?
    {
        var candidate: NSViewController? = viewController
        while let current = candidate {
            if let splitViewController = current as? NSSplitViewController {
                return splitViewController
            }
            candidate = current.parent
        }
        return nil
    }

    private static func firstSplitViewController(in viewController: NSViewController) -> NSSplitViewController? {
        if let splitViewController = viewController as? NSSplitViewController {
            return splitViewController
        }
        for child in viewController.children {
            if let splitViewController = Self.firstSplitViewController(in: child) {
                return splitViewController
            }
        }
        return nil
    }
}

private struct CodexWorkspaceCommandBar: View {
    @Binding var selectedTab: CodexLocalProjectUsageWindowTab
    let historyDays: Int
    @Binding var customHistoryDays: Int
    let isRefreshing: Bool
    let setHistoryDays: (Int) -> Void
    let refresh: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Picker(L("codex_workspaces_view"), selection: self.$selectedTab) {
                ForEach(CodexLocalProjectUsageWindowTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 228)

            Spacer(minLength: 16)

            if self.selectedTab != .models {
                Menu {
                    ForEach([7, 30, 60, 90, 180, 365], id: \.self) { days in
                        Button {
                            self.setHistoryDays(days)
                        } label: {
                            if days == self.historyDays {
                                Label(self.historyTitle(days), systemImage: "checkmark")
                            } else {
                                Text(self.historyTitle(days))
                            }
                        }
                    }
                    Divider()
                    HStack {
                        TextField(L("codex_workspaces_days"), value: self.$customHistoryDays, format: .number)
                            .frame(width: 58)
                        Stepper("", value: self.$customHistoryDays, in: 1...365)
                            .labelsHidden()
                        Button(L("apply")) { self.setHistoryDays(self.customHistoryDays) }
                    }
                } label: {
                    Text(self.historyTitle(self.historyDays))
                        .monospacedDigit()
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .fixedSize()

                Button(action: self.refresh) {
                    if self.isRefreshing {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(self.isRefreshing)
                .help(L("codex_workspaces_refresh_usage_data"))
                .accessibilityLabel(L("codex_workspaces_refresh_usage_data"))
            }
        }
        .padding(.horizontal, CodexLocalProjectUsageWindowLayout.detailPadding)
        .frame(height: CodexLocalProjectUsageWindowLayout.commandHeight)
    }

    private func historyTitle(_ days: Int) -> String {
        L("codex_workspaces_last_days", days)
    }
}

private struct CodexWorkspaceKeyboardCommands: View {
    @Binding var selectedTab: CodexLocalProjectUsageWindowTab
    let refresh: () -> Void

    var body: some View {
        HStack {
            Button(L("codex_workspaces_overview")) { self.selectedTab = .overview }
                .keyboardShortcut("1", modifiers: .command)
            Button(L("codex_workspaces_sessions")) { self.selectedTab = .sessions }
                .keyboardShortcut("2", modifiers: .command)
            Button(L("codex_workspaces_models")) { self.selectedTab = .models }
                .keyboardShortcut("3", modifiers: .command)
            Button(L("codex_workspaces_refresh_usage_data"), action: self.refresh)
                .keyboardShortcut("r", modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}
