import SwiftUI

/// Menu-backed settings selector that avoids disabled `Picker` items on macOS 27 when built with the macOS 26 SDK.
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

    var body: some View {
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
    }
}

enum GeneralSettingsMenuOptions {
    static let languages = AppLanguage.allCases.map(\.rawValue)
    static let refreshFrequencies = RefreshFrequency.allCases

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
}

enum MenuSettingsMenuOptions {
    static let weeklyProgressWorkDays: [Int?] = [nil, 4, 5, 7]
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
