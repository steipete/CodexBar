import CodexBarCore
import Foundation

enum MenuBarIconStyle: String, CaseIterable {
    case critters
    case bars
    case iconAndPercent

    var label: String {
        switch self {
        case .critters: L("menu_bar_style_critters")
        case .bars: L("menu_bar_style_bars")
        case .iconAndPercent: L("menu_bar_style_icon_percent")
        }
    }
}

enum SwitcherRowsOption: String, CaseIterable {
    case icons
    case progress

    var label: String {
        switch self {
        case .icons: L("switcher_rows_icons")
        case .progress: L("switcher_rows_progress")
        }
    }
}

enum UsageBarsFillOption: String, CaseIterable {
    case remaining
    case used

    var label: String {
        switch self {
        case .remaining: L("usage_bars_fill_remaining")
        case .used: L("usage_bars_fill_used")
        }
    }
}

enum ResetTimesOption: String, CaseIterable {
    case countdown
    case clock

    var label: String {
        switch self {
        case .countdown: L("reset_times_countdown")
        case .clock: L("reset_times_clock")
        }
    }
}

enum ConfettiCelebrationOption: String, CaseIterable {
    case off
    case session
    case weekly
    case both

    var label: String {
        switch self {
        case .off: L("confetti_option_off")
        case .session: L("confetti_option_session")
        case .weekly: L("confetti_option_weekly")
        case .both: L("confetti_option_both")
        }
    }
}

enum CostSummaryOption: String, CaseIterable {
    case off
    case inlineSummary
    case costSubmenu
    case both

    var label: String {
        switch self {
        case .off: L("cost_summary_off")
        case .inlineSummary: CostSummaryDisplayStyle.inlineSummary.label
        case .costSubmenu: CostSummaryDisplayStyle.costSubmenu.label
        case .both: CostSummaryDisplayStyle.both.label
        }
    }
}

enum AgentSessionLabelStyle: String, CaseIterable {
    case project
    case descriptive
    case descriptiveAndProject

    var label: String {
        switch self {
        case .project: L("agent_session_label_project")
        case .descriptive: L("agent_session_label_descriptive")
        case .descriptiveAndProject: L("agent_session_label_descriptive_and_project")
        }
    }

    func label(for session: AgentSession) -> String {
        let project = session.projectName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let descriptive = session.sessionName?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch self {
        case .project:
            return project?.nilIfEmpty ?? L("agent_session_unknown_project")
        case .descriptive:
            return descriptive?.nilIfEmpty ?? project?.nilIfEmpty ?? L("agent_session_unknown_project")
        case .descriptiveAndProject:
            guard let descriptive = descriptive?.nilIfEmpty else {
                return project?.nilIfEmpty ?? L("agent_session_unknown_project")
            }
            guard let project = project?.nilIfEmpty,
                  descriptive.caseInsensitiveCompare(project) != .orderedSame
            else { return descriptive }
            return "\(descriptive) · \(project)"
        }
    }
}

extension String {
    fileprivate var nilIfEmpty: String? {
        self.isEmpty ? nil : self
    }
}

extension SettingsStore {
    var menuBarIconStyle: MenuBarIconStyle {
        get {
            if self.menuBarShowsBrandIconWithPercent {
                return .iconAndPercent
            }
            return self.menuBarHidesCritters ? .bars : .critters
        }
        set {
            switch newValue {
            case .critters:
                self.menuBarShowsBrandIconWithPercent = false
                self.menuBarHidesCritters = false
            case .bars:
                self.menuBarShowsBrandIconWithPercent = false
                self.menuBarHidesCritters = true
            case .iconAndPercent:
                self.menuBarShowsBrandIconWithPercent = true
            }
        }
    }

    var switcherRowsOption: SwitcherRowsOption {
        get { self.switcherShowsIcons ? .icons : .progress }
        set { self.switcherShowsIcons = newValue == .icons }
    }

    var usageBarsFillOption: UsageBarsFillOption {
        get { self.usageBarsShowUsed ? .used : .remaining }
        set { self.usageBarsShowUsed = newValue == .used }
    }

    var resetTimesOption: ResetTimesOption {
        get { self.resetTimesShowAbsolute ? .clock : .countdown }
        set { self.resetTimesShowAbsolute = newValue == .clock }
    }

    var confettiCelebrationOption: ConfettiCelebrationOption {
        get {
            switch (self.confettiOnSessionLimitResetsEnabled, self.confettiOnWeeklyLimitResetsEnabled) {
            case (false, false): .off
            case (true, false): .session
            case (false, true): .weekly
            case (true, true): .both
            }
        }
        set {
            self.confettiOnSessionLimitResetsEnabled = newValue == .session || newValue == .both
            self.confettiOnWeeklyLimitResetsEnabled = newValue == .weekly || newValue == .both
        }
    }

    var costSummaryOption: CostSummaryOption {
        get {
            guard self.costUsageEnabled else { return .off }
            switch self.costSummaryDisplayStyle {
            case .inlineSummary: return .inlineSummary
            case .costSubmenu: return .costSubmenu
            case .both: return .both
            }
        }
        set {
            switch newValue {
            case .off:
                self.costUsageEnabled = false
            case .inlineSummary:
                self.costSummaryDisplayStyle = .inlineSummary
                self.costUsageEnabled = true
            case .costSubmenu:
                self.costSummaryDisplayStyle = .costSubmenu
                self.costUsageEnabled = true
            case .both:
                self.costSummaryDisplayStyle = .both
                self.costUsageEnabled = true
            }
        }
    }

    func menuBarMetricPreference(for provider: UsageProvider) -> MenuBarMetricPreference {
        if Self.isBalanceOnlyProvider(provider), provider != .mistral {
            return .automatic
        }
        if provider == .mistral {
            let raw = self.menuBarMetricPreferencesRaw[provider.rawValue] ?? ""
            let preference = MenuBarMetricPreference(rawValue: raw) ?? .automatic
            switch preference {
            case .automatic, .monthlyPlan:
                return preference
            case .primary, .secondary, .primaryAndSecondary, .tertiary, .extraUsage, .average:
                return .automatic
            }
        }
        if provider == .openrouter {
            let raw = self.menuBarMetricPreferencesRaw[provider.rawValue] ?? ""
            let preference = MenuBarMetricPreference(rawValue: raw) ?? .automatic
            switch preference {
            case .automatic, .primary:
                return preference
            case .secondary, .primaryAndSecondary, .average, .tertiary, .extraUsage, .monthlyPlan:
                return .automatic
            }
        }
        let raw = self.menuBarMetricPreferencesRaw[provider.rawValue] ?? ""
        let preference = MenuBarMetricPreference(rawValue: raw) ?? .automatic
        if preference == .average, !self.menuBarMetricSupportsAverage(for: provider) {
            return .automatic
        }
        if preference == .primaryAndSecondary, !self.menuBarMetricSupportsPrimaryAndSecondary(for: provider) {
            return .automatic
        }
        if preference == .tertiary, !self.menuBarMetricSupportsTertiary(for: provider) {
            return .automatic
        }
        if preference == .extraUsage, !self.menuBarMetricSupportsExtraUsage(for: provider) {
            return .automatic
        }
        if preference == .monthlyPlan {
            return .automatic
        }
        return preference
    }

    func setMenuBarMetricPreference(_ preference: MenuBarMetricPreference, for provider: UsageProvider) {
        if Self.isBalanceOnlyProvider(provider), provider != .mistral {
            self.menuBarMetricPreferencesRaw[provider.rawValue] = MenuBarMetricPreference.automatic.rawValue
            return
        }
        if provider == .mistral {
            switch preference {
            case .automatic, .monthlyPlan:
                self.menuBarMetricPreferencesRaw[provider.rawValue] = preference.rawValue
            case .primary, .secondary, .primaryAndSecondary, .tertiary, .extraUsage, .average:
                self.menuBarMetricPreferencesRaw[provider.rawValue] = MenuBarMetricPreference.automatic.rawValue
            }
            return
        }
        if provider == .openrouter {
            switch preference {
            case .automatic, .primary:
                self.menuBarMetricPreferencesRaw[provider.rawValue] = preference.rawValue
            case .secondary, .primaryAndSecondary, .average, .tertiary, .extraUsage, .monthlyPlan:
                self.menuBarMetricPreferencesRaw[provider.rawValue] = MenuBarMetricPreference.automatic.rawValue
            }
            return
        }
        if preference == .primaryAndSecondary, !self.menuBarMetricSupportsPrimaryAndSecondary(for: provider) {
            self.menuBarMetricPreferencesRaw[provider.rawValue] = MenuBarMetricPreference.automatic.rawValue
            return
        }
        if preference == .tertiary, !self.menuBarMetricSupportsTertiary(for: provider) {
            self.menuBarMetricPreferencesRaw[provider.rawValue] = MenuBarMetricPreference.automatic.rawValue
            return
        }
        if preference == .extraUsage, !self.menuBarMetricSupportsExtraUsage(for: provider) {
            self.menuBarMetricPreferencesRaw[provider.rawValue] = MenuBarMetricPreference.automatic.rawValue
            return
        }
        if preference == .monthlyPlan {
            self.menuBarMetricPreferencesRaw[provider.rawValue] = MenuBarMetricPreference.automatic.rawValue
            return
        }
        self.menuBarMetricPreferencesRaw[provider.rawValue] = preference.rawValue
    }

    func menuBarMetricSupportsAverage(for provider: UsageProvider) -> Bool {
        provider == .gemini
    }

    func menuBarMetricSupportsPrimaryAndSecondary(for provider: UsageProvider) -> Bool {
        provider == .codex || provider == .claude
    }

    func menuBarMetricSupportsTertiary(for provider: UsageProvider) -> Bool {
        provider == .cursor || provider == .perplexity || provider == .zai
    }

    func menuBarMetricSupportsTertiary(for provider: UsageProvider, snapshot: UsageSnapshot?) -> Bool {
        if provider == .cursor || provider == .zai {
            return snapshot?.tertiary != nil
        }
        return self.menuBarMetricSupportsTertiary(for: provider)
    }

    func menuBarMetricSupportsExtraUsage(for provider: UsageProvider) -> Bool {
        provider == .cursor || provider == .claude
    }

    func menuBarMetricSupportsExtraUsage(for provider: UsageProvider, snapshot: UsageSnapshot?) -> Bool {
        guard self.menuBarMetricSupportsExtraUsage(for: provider) else { return false }
        guard let cost = snapshot?.providerCost else { return false }
        return cost.limit > 0
    }

    func menuBarMetricPreference(for provider: UsageProvider, snapshot: UsageSnapshot?) -> MenuBarMetricPreference {
        let preference = self.menuBarMetricPreference(for: provider)
        if preference == .tertiary,
           !self.menuBarMetricSupportsTertiary(for: provider, snapshot: snapshot)
        {
            return .automatic
        }
        if preference == .extraUsage,
           !self.menuBarMetricSupportsExtraUsage(for: provider, snapshot: snapshot)
        {
            return .automatic
        }
        return preference
    }

    func isCostUsageEffectivelyEnabled(for provider: UsageProvider) -> Bool {
        let isEnabled = self.costUsageEnabled ||
            (provider == .codex && self.codexLocalSessionCostLedgerEnabled)
        return isEnabled && ProviderDescriptorRegistry.descriptor(for: provider).tokenCost.supportsTokenCost
    }

    var resetTimeDisplayStyle: ResetTimeDisplayStyle {
        self.resetTimesShowAbsolute ? .absolute : .countdown
    }

    static func isBalanceOnlyProvider(_ provider: UsageProvider) -> Bool {
        switch provider {
        case .deepseek, .deepinfra, .mistral, .moonshot, .poe:
            true
        default:
            false
        }
    }
}
