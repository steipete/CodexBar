import CodexBarCore
import SwiftUI

struct ProviderModelLimitDraft: Identifiable, Equatable {
    let id = UUID()
    var model = ""
    var tpm = ""
    var rpm = ""

    init(limit: ProviderModelRateLimit? = nil) {
        if let limit {
            self.model = limit.model
            self.tpm = ProviderRateLimitNumber.format(limit.tokensPerMinute)
            self.rpm = limit.requestsPerMinute.map(ProviderRateLimitNumber.format) ?? ""
        }
    }

    var value: ProviderModelRateLimit? {
        let name = self.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let rpm = self.rpm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let tpm = ProviderRateLimitNumber.parse(self.tpm),
              rpm.isEmpty || ProviderRateLimitNumber.parse(rpm) != nil else { return nil }
        return .init(model: name, tokensPerMinute: tpm, requestsPerMinute: ProviderRateLimitNumber.parse(rpm))
    }
}

@MainActor
struct ProviderSettingsModelLimitsRowView: View {
    let descriptor: ProviderSettingsModelLimitsDescriptor
    @State private var rows: [ProviderModelLimitDraft]

    init(descriptor: ProviderSettingsModelLimitsDescriptor) {
        self.descriptor = descriptor
        self._rows = State(initialValue: descriptor.binding.wrappedValue.map { .init(limit: $0) })
    }

    var body: some View {
        Section {
            if !self.rows.isEmpty {
                HStack(spacing: 8) {
                    Text(L("Model")).frame(maxWidth: .infinity, alignment: .leading)
                    Text(verbatim: "TPM").frame(width: 85, alignment: .leading)
                    Text(L("RPM (optional)")).frame(width: 110, alignment: .leading)
                    Color.clear.frame(width: 16, height: 1)
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            ForEach(self.$rows) { $row in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        TextField(L("Model"), text: $row.model)
                            .labelsHidden().textFieldStyle(.roundedBorder)
                            .accessibilityLabel(L("Model"))
                        TextField(text: $row.tpm) { Text(verbatim: "TPM") }
                            .labelsHidden().textFieldStyle(.roundedBorder)
                            .frame(width: 85).accessibilityLabel(L("Tokens per minute"))
                        TextField(L("RPM (optional)"), text: $row.rpm)
                            .labelsHidden().textFieldStyle(.roundedBorder)
                            .frame(width: 110).accessibilityLabel(L("RPM (optional)"))
                        Button {
                            self.rows.removeAll { $0.id == row.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .frame(width: 16)
                        .accessibilityLabel(L("Remove"))
                    }
                    if row.value == nil {
                        Text(L("Enter a model and positive limits, such as 40M TPM and 15k RPM."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Button(L("Add model")) { self.rows.append(.init()) }
            ProviderSettingsButtonsView(actions: self.descriptor.actions)
        } header: {
            Text(L(self.descriptor.title))
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                SettingsSectionFooter(L(self.descriptor.subtitle))
                if let scopeText = self.descriptor.scopeText {
                    SettingsSectionFooter(scopeText)
                }
            }
        }
        .onChange(of: self.rows) { _, rows in
            // Keep edits local until every row is valid, preserving the last saved limits while typing.
            let values = rows.compactMap(\.value)
            guard values.count == rows.count else { return }
            self.descriptor.binding.wrappedValue = values
        }
        .onChange(of: self.descriptor.binding.wrappedValue) { _, limits in
            guard ProviderModelRateLimit.validated(self.rows.compactMap(\.value)) != limits else { return }
            self.rows = limits.map { .init(limit: $0) }
        }
    }
}
