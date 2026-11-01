import SwiftUI

/// Native pop-up settings selector shared by settings rows.
/// macOS 26 SDK builds show disabled `Picker` items on macOS 27 (#1904), so they keep a menu-backed selector.
struct SettingsMenuPicker<Value: Hashable, Label: View, OptionLabel: View>: View {
    @Binding private var selection: Value
    private let options: [Value]
    private let label: () -> Label
    private let optionLabel: (Value) -> OptionLabel

    init(
        selection: Binding<Value>,
        options: [Value],
        @ViewBuilder label: @escaping () -> Label,
        @ViewBuilder optionLabel: @escaping (Value) -> OptionLabel)
    {
        self._selection = selection
        self.options = options
        self.label = label
        self.optionLabel = optionLabel
    }

    private var displayedOptions: [Value] {
        SettingsMenuPickerOptions.displayed(self.options, selection: self.selection)
    }

    var body: some View {
        // Swift 6.4 ships with Xcode 27, so older compilers mean a macOS 26 SDK build.
        #if compiler(>=6.4)
        Picker(selection: self.$selection) {
            ForEach(self.displayedOptions, id: \.self) { option in
                self.optionLabel(option)
                    .tag(option)
            }
        } label: {
            self.label()
        }
        .pickerStyle(.menu)
        #else
        LabeledContent {
            Menu {
                ForEach(self.options, id: \.self) { option in
                    Button {
                        self.selection = option
                    } label: {
                        HStack {
                            if self.selection == option {
                                Image(systemName: "checkmark")
                            }
                            self.optionLabel(option)
                        }
                    }
                }
            } label: {
                self.optionLabel(self.selection)
                    .foregroundStyle(.primary)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .fixedSize()
        } label: {
            self.label()
        }
        #endif
    }
}

enum SettingsMenuPickerOptions {
    /// Native `Picker` only shows a selection with a matching tag, so keep imported off-list values visible.
    static func displayed<Value: Hashable>(_ options: [Value], selection: Value) -> [Value] {
        options.contains(selection) ? options : options + [selection]
    }
}

enum GeneralSettingsMenuOptions {
    static let languages = AppLanguage.allCases.map(\.rawValue)
    static let refreshFrequencies = RefreshFrequency.allCases
    static let lowPowerModePreferences = LowPowerModePreference.allCases

    static func terminalApps(selected: TerminalApp) -> [TerminalApp] {
        TerminalApp.pickerOptions(selected: selected)
    }

    static func terminalApps(
        selected: TerminalApp,
        applicationURL: (String) -> URL?) -> [TerminalApp]
    {
        TerminalApp.pickerOptions(selected: selected, applicationURL: applicationURL)
    }
}

enum MenuBarSettingsMenuOptions {
    static let displayModes = MenuBarDisplayMode.allCases
    static let iconStyles = MenuBarIconStyle.allCases
    static let switcherRows = SwitcherRowsOption.allCases
    static let mergedIconStyles = MergedIconDisplayStyle.allCases
    static let unifiedIconSources = UnifiedIconSource.allCases
}

enum MenuSettingsMenuOptions {
    static let mergedOverviewLayouts = MergedOverviewLayout.allCases
    static let weeklyProgressWorkDays: [Int?] = [nil, 4, 5, 6, 7]
    static let workdayTickAppearances = WorkdayTickAppearance.allCases
    static let multiAccountLayouts = MultiAccountMenuLayout.allCases
    static let usageBarsFill = UsageBarsFillOption.allCases
    static let resetTimes = ResetTimesOption.allCases
    static let costSummaries = CostSummaryOption.allCases
    static let agentSessionLabelStyles = AgentSessionLabelStyle.allCases

    static func weeklyProgressWorkDaysLabel(_ workDays: Int?) -> String {
        switch workDays {
        case nil: L("Automatic")
        case 4: L("4 days")
        case 5: L("5 days")
        case 7: L("7 days")
        case let workDays?: L("%d days", workDays)
        }
    }
}

enum NotificationsSettingsMenuOptions {
    static let confettiCelebrations = ConfettiCelebrationOption.allCases
}
