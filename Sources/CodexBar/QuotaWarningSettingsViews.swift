import CodexBarCore
#if os(macOS)
import AppKit
#endif
import SwiftUI

struct QuotaWarningSettingsVisibility: Equatable {
    let showsThresholdControls: Bool
    let showsDeliveryControls: Bool

    init(thresholdWarningsEnabled: Bool, predictiveWarningsEnabled: Bool) {
        self.showsThresholdControls = thresholdWarningsEnabled
        self.showsDeliveryControls = thresholdWarningsEnabled || predictiveWarningsEnabled
    }
}

@MainActor
struct GlobalQuotaWarningSettingsView: View {
    @Bindable var settings: SettingsStore
    let showsThresholdControls: Bool

    init(settings: SettingsStore, showsThresholdControls: Bool = true) {
        self.settings = settings
        self.showsThresholdControls = showsThresholdControls
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if self.showsThresholdControls {
                QuotaWarningWindowThresholdRows(settings: self.settings)

                Text(L("quota_warning_global_threshold_subtitle"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle(isOn: self.$settings.quotaWarningSoundEnabled) {
                Text(L("quota_warning_sound"))
                    .font(.footnote)
            }
            .toggleStyle(.checkbox)

            Toggle(isOn: self.$settings.quotaWarningOnScreenAlertEnabled) {
                Text(L("quota_warning_onscreen_alert"))
                    .font(.footnote)
            }
            .toggleStyle(.checkbox)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 22)
        .background(FocusResigningBackground())
        .listRowSeparator(.hidden)
    }
}

@MainActor
struct ProviderQuotaWarningSettingsView: View {
    private static let windowRowMinHeight: CGFloat = 26
    private static let thresholdFieldWidth: CGFloat = 40

    let provider: UsageProvider
    @Bindable var settings: SettingsStore

    var body: some View {
        Section {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                self.windowRow(.session)
                self.windowRow(.weekly)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowSeparator(.hidden)
            .disabled(!self.controlsEnabled)
            .opacity(self.controlsEnabled ? 1 : 0.45)
        } header: {
            Text(L("quota_warnings_title"))
        } footer: {
            SettingsSectionFooter(self.footerText)
        }
        .background(FocusResigningBackground())
    }

    var controlsEnabled: Bool {
        self.settings.quotaWarningNotificationsEnabled || self.settings.quotaWarningMarkersVisible
    }

    var footerText: String {
        if self.settings.quotaWarningNotificationsEnabled {
            return L("quota_warning_provider_inherits")
        }
        if self.settings.quotaWarningMarkersVisible {
            return L("quota_warning_provider_markers_only")
        }
        return L("quota_warning_provider_disabled")
    }

    private func windowRow(_ window: QuotaWarningWindow) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(window.localizedCapitalizedDisplayName)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: true, vertical: false)
                .frame(minHeight: Self.windowRowMinHeight, alignment: .center)
                .gridColumnAlignment(.leading)

            Picker(window.localizedCapitalizedDisplayName, selection: self.overrideModeBinding(for: window)) {
                Text(L("quota_warning_global")).tag(ProviderQuotaWarningOverrideMode.global)
                Text(L("Custom")).tag(ProviderQuotaWarningOverrideMode.custom)
                Text(L("quota_warning_off")).tag(ProviderQuotaWarningOverrideMode.off)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            .fixedSize()
            .frame(minHeight: Self.windowRowMinHeight, alignment: .center)
            .gridColumnAlignment(.leading)

            self.windowDetail(window)
                .frame(minHeight: Self.windowRowMinHeight, alignment: .leading)
                .gridColumnAlignment(.leading)
        }
    }

    @ViewBuilder
    private func windowDetail(_ window: QuotaWarningWindow) -> some View {
        switch self.overrideMode(for: window) {
        case .custom:
            QuotaWarningThresholdField(
                title: "",
                subtitle: "",
                accessibilityContext: window.localizedCapitalizedDisplayName,
                shouldCommitOnDisappear: {
                    self.shouldCommitThresholdEditorOnDisappear(for: window)
                },
                thresholds: {
                    self.settings.resolvedQuotaWarningThresholds(provider: self.provider, window: window)
                },
                setThresholds: {
                    self.settings.setQuotaWarningThresholdsIfOverridden(
                        provider: self.provider,
                        window: window,
                        thresholds: $0)
                },
                fieldWidth: Self.thresholdFieldWidth,
                controlFont: .subheadline)
                .fixedSize(horizontal: true, vertical: false)
        case .off:
            EmptyView()
        case .global:
            Text(String(format: L("quota_warning_inherited"), Self.thresholdText(
                self.settings.quotaWarningThresholds(window),
                enabled: self.settings.quotaWarningWindowEnabled(window))))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    func overrideModeBinding(for window: QuotaWarningWindow) -> Binding<ProviderQuotaWarningOverrideMode> {
        Binding(
            get: { self.overrideMode(for: window) },
            set: { mode in
                let currentMode = self.overrideMode(for: window)
                guard mode != currentMode else { return }

                switch mode {
                case .custom:
                    self.settings.setQuotaWarningOverride(
                        provider: self.provider,
                        window: window,
                        thresholds: self.settings.explicitQuotaWarningThresholds(
                            provider: self.provider,
                            window: window),
                        enabled: true)
                case .off:
                    self.settings.setQuotaWarningOverride(
                        provider: self.provider,
                        window: window,
                        thresholds: currentMode == .custom
                            ? self.settings.explicitQuotaWarningThresholds(
                                provider: self.provider,
                                window: window)
                            : nil,
                        enabled: false)
                case .global:
                    self.settings.setQuotaWarningOverride(
                        provider: self.provider,
                        window: window,
                        thresholds: nil,
                        enabled: nil)
                }
            })
    }

    func overrideMode(for window: QuotaWarningWindow) -> ProviderQuotaWarningOverrideMode {
        guard self.settings.hasQuotaWarningOverride(provider: self.provider, window: window) else {
            return .global
        }
        return self.settings.quotaWarningEnabled(provider: self.provider, window: window) ? .custom : .off
    }

    func shouldCommitThresholdEditorOnDisappear(for window: QuotaWarningWindow) -> Bool {
        let mode = self.overrideMode(for: window)
        return mode == .custom || mode == .off
    }

    static func thresholdText(_ thresholds: [Int], enabled: Bool) -> String {
        guard enabled else { return L("quota_warning_off") }
        let activeThresholds = QuotaWarningThresholds.active(thresholds)
        guard let upperThreshold = activeThresholds.first else {
            return L("quota_warning_depleted_only")
        }

        var parts: [String] = []
        parts.append("\(L("quota_warning_warning")) \(upperThreshold)%")
        if let lowerThreshold = activeThresholds.dropFirst().first {
            parts.append("\(L("quota_warning_critical")) \(lowerThreshold)%")
        }
        parts.append(contentsOf: activeThresholds.dropFirst(2).map { "\($0)%" })
        return parts.joined(separator: ", ")
    }
}

enum ProviderQuotaWarningOverrideMode: Hashable {
    case global
    case custom
    case off
}

struct FocusResigningBackground: View {
    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture {
                #if os(macOS)
                NSApplication.shared.keyWindow?.makeFirstResponder(nil)
                #endif
            }
    }
}

extension QuotaWarningWindow {
    var localizedCapitalizedDisplayName: String {
        switch self {
        case .session: L("quota_warning_session_capitalized")
        case .weekly: L("quota_warning_weekly_capitalized")
        }
    }
}

@MainActor
private struct QuotaWarningWindowThresholdRows: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            self.windowThresholdRow(.session)
            self.windowThresholdRow(.weekly)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func windowThresholdRow(_ window: QuotaWarningWindow) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Toggle(isOn: Binding(
                get: { self.settings.quotaWarningWindowEnabled(window) },
                set: { self.settings.setQuotaWarningWindowEnabled(window, enabled: $0) }))
            {
                Text(window.localizedCapitalizedDisplayName)
                    .font(.footnote.weight(.semibold))
                    .fixedSize(horizontal: true, vertical: false)
            }
            .toggleStyle(.checkbox)
            .gridColumnAlignment(.leading)

            QuotaWarningThresholdField(
                title: "",
                subtitle: "",
                accessibilityContext: window.localizedCapitalizedDisplayName,
                thresholds: { self.settings.quotaWarningThresholds(window) },
                setThresholds: { self.settings.setQuotaWarningThresholds(window, thresholds: $0) })
                .disabled(!self.settings.quotaWarningWindowEnabled(window))
                .opacity(self.settings.quotaWarningWindowEnabled(window) ? 1 : 0.45)
                .gridColumnAlignment(.leading)
        }
    }
}

@MainActor
private struct QuotaWarningThresholdField: View {
    private static let defaultFieldWidth: CGFloat = 44

    let title: String
    let subtitle: String
    var accessibilityContext: String = ""
    var shouldCommitOnDisappear: () -> Bool = { true }
    let thresholds: () -> [Int]
    let setThresholds: ([Int]) -> Void
    var fieldWidth: CGFloat = Self.defaultFieldWidth
    var controlFont: Font = .footnote
    var titleFont: Font = .footnote.weight(.semibold)

    @State private var draft = QuotaWarningThresholdEditorText.Draft()
    @FocusState private var focusedField: QuotaWarningThresholdEditorText.Field?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            self.horizontalEditor

            if !self.subtitle.isEmpty {
                Text(self.subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { self.updateText(from: self.thresholds()) }
        .onChange(of: self.focusedField) { previous, current in
            if previous != nil, current == nil {
                self.commit()
            }
        }
        .onChange(of: self.thresholds()) { _, value in
            if self.focusedField == nil {
                self.updateText(from: value)
            }
        }
        .onDisappear {
            if self.shouldCommitOnDisappear() {
                self.commit()
            }
        }
        .background(self.focusMonitor)
    }

    private var horizontalEditor: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            self.titleView

            self.upperField
            self.lowerField
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var titleView: some View {
        if !self.title.isEmpty {
            Text(self.title)
                .font(self.titleFont)
                .frame(width: 110, alignment: .leading)
        }
    }

    private var upperField: some View {
        self.thresholdInput(
            label: L("quota_warning_warning"),
            placeholder: "50",
            text: self.thresholdTextBinding(.upper),
            field: .upper)
    }

    private var lowerField: some View {
        self.thresholdInput(
            label: L("quota_warning_critical"),
            placeholder: "20",
            text: self.thresholdTextBinding(.lower),
            field: .lower)
    }

    private func thresholdInput(
        label: String,
        placeholder: String,
        text: Binding<String>,
        field: QuotaWarningThresholdEditorText.Field) -> some View
    {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(label)
                .font(self.controlFont)
                .foregroundStyle(.secondary)

            TextField(label, text: text, prompt: Text(verbatim: placeholder))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .font(self.controlFont)
                .multilineTextAlignment(.trailing)
                .frame(width: self.fieldWidth)
                .focused(self.$focusedField, equals: field)
                .onSubmit {
                    self.commit()
                    self.focusedField = nil
                }
                .accessibilityLabel(Text(self.accessibilityLabel(for: label)))

            Text(verbatim: "%")
                .font(self.controlFont)
                .foregroundStyle(.secondary)
        }
    }

    private func thresholdTextBinding(_ field: QuotaWarningThresholdEditorText.Field) -> Binding<String> {
        Binding(
            get: { self.draft.text(for: field) },
            set: { self.draft.setText($0, for: field) })
    }

    private func commit() {
        guard let sanitized = self.draft.takeResolvedThresholds() else { return }
        self.setThresholds(sanitized)
        self.updateText(from: sanitized)
    }

    private func updateText(from thresholds: [Int]) {
        self.draft.update(from: thresholds)
    }

    private func accessibilityLabel(for label: String) -> String {
        let context = self.title.isEmpty ? self.accessibilityContext : self.title
        guard !context.isEmpty else { return label }
        return "\(context), \(label)"
    }

    @ViewBuilder
    private var focusMonitor: some View {
        #if os(macOS)
        QuotaWarningFocusMonitor(isActive: self.focusedField != nil) {
            NSApplication.shared.keyWindow?.makeFirstResponder(nil)
            self.focusedField = nil
        }
        #else
        EmptyView()
        #endif
    }
}

#if os(macOS)
private struct QuotaWarningFocusMonitor: NSViewRepresentable {
    let isActive: Bool
    let onOutsideClick: () -> Void

    func makeNSView(context: Context) -> QuotaWarningFocusMonitorView {
        let view = QuotaWarningFocusMonitorView()
        view.isActive = self.isActive
        view.onOutsideClick = self.onOutsideClick
        return view
    }

    func updateNSView(_ nsView: QuotaWarningFocusMonitorView, context: Context) {
        nsView.isActive = self.isActive
        nsView.onOutsideClick = self.onOutsideClick
    }

    static func dismantleNSView(_ nsView: QuotaWarningFocusMonitorView, coordinator: ()) {
        nsView.invalidate()
    }
}

private final class QuotaWarningFocusMonitorView: NSView {
    var onOutsideClick: (() -> Void)?
    var isActive: Bool = false {
        didSet { self.updateMonitor() }
    }

    private var monitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func invalidate() {
        self.isActive = false
        self.onOutsideClick = nil
    }

    private func updateMonitor() {
        if self.isActive {
            self.installMonitor()
        } else {
            self.removeMonitor()
        }
    }

    private func installMonitor() {
        guard self.monitor == nil else { return }
        self.monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func handle(_ event: NSEvent) {
        guard self.isActive else { return }
        guard let window = self.window, event.window === window else { return }

        let location = self.convert(event.locationInWindow, from: nil)
        guard !self.bounds.contains(location) else { return }
        guard !Self.eventHitsTextInput(event) else { return }

        DispatchQueue.main.async { [weak self] in
            self?.onOutsideClick?()
        }
    }

    private static func eventHitsTextInput(_ event: NSEvent) -> Bool {
        guard let contentView = event.window?.contentView else { return false }
        let location = contentView.convert(event.locationInWindow, from: nil)
        guard let hitView = contentView.hitTest(location) else { return false }
        return hitView.hasAncestor(of: NSTextField.self) || hitView.hasAncestor(of: NSTextView.self)
    }
}

extension NSView {
    fileprivate func hasAncestor<T: NSView>(of type: T.Type) -> Bool {
        var view: NSView? = self
        while let current = view {
            if current is T {
                return true
            }
            view = current.superview
        }
        return false
    }
}
#endif

enum QuotaWarningThresholdEditorText {
    enum Field: Hashable {
        case upper
        case lower
    }

    struct Draft {
        private(set) var upperText: String
        private(set) var lowerText: String
        private let initialUpperText: String
        private let initialLowerText: String

        var isDirty: Bool {
            self.upperText != self.initialUpperText || self.lowerText != self.initialLowerText
        }

        init(thresholds: [Int] = QuotaWarningThresholds.defaults) {
            let pair = QuotaWarningThresholdEditorText.displayText(from: thresholds)
            let upperText = pair.upper.map(String.init) ?? ""
            let lowerText = pair.lower.map(String.init) ?? ""
            self.upperText = upperText
            self.lowerText = lowerText
            self.initialUpperText = upperText
            self.initialLowerText = lowerText
        }

        func text(for field: Field) -> String {
            switch field {
            case .upper: self.upperText
            case .lower: self.lowerText
            }
        }

        mutating func setText(_ value: String, for field: Field) {
            let filtered = QuotaWarningThresholdEditorText.filteredIntegerText(value)
            guard self.text(for: field) != filtered else { return }
            switch field {
            case .upper: self.upperText = filtered
            case .lower: self.lowerText = filtered
            }
        }

        mutating func update(from thresholds: [Int]) {
            self = Draft(thresholds: thresholds)
        }

        mutating func takeResolvedThresholds() -> [Int]? {
            guard self.isDirty else { return nil }
            let thresholds = QuotaWarningThresholdEditorText.resolvedThresholds(
                upperText: self.upperText,
                lowerText: self.lowerText)
            self.update(from: thresholds)
            return thresholds
        }
    }

    static func displayText(from thresholds: [Int]) -> (upper: Int?, lower: Int?) {
        let sanitized = QuotaWarningThresholds.sanitized(thresholds)
        return (sanitized.first, sanitized.dropFirst().first)
    }

    static func resolvedThresholds(upperText: String, lowerText: String) -> [Int] {
        QuotaWarningThresholds.resolved(
            upper: self.integer(from: upperText),
            lower: self.integer(from: lowerText))
    }

    static func filteredIntegerText(_ text: String) -> String {
        String(text.filter(\.isNumber).prefix(2))
    }

    private static func integer(from text: String) -> Int? {
        guard !text.isEmpty else { return nil }
        return Int(text)
    }
}
