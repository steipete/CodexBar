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
