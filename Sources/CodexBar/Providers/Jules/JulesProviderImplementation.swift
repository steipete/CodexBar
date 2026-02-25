import CodexBarCore
import CodexBarMacroSupport
import Foundation
import SwiftUI

@ProviderImplementationRegistration
public struct JulesProviderImplementation: ProviderImplementation {
    public static let id: UsageProvider = .jules

    public static func makeSettingsView(
        provider: ProviderDescriptor,
        store: UsageStore,
        context: ProviderSettingsContext)
        -> AnyView
    {
        AnyView(JulesSettingsView(provider: provider, store: store))
    }

    public static func makeLoginView(
        provider: ProviderDescriptor,
        store: UsageStore,
        context: ProviderSettingsContext)
        -> AnyView?
    {
        AnyView(JulesLoginView())
    }
}

struct JulesSettingsView: View {
    let provider: ProviderDescriptor
    @ObservedObject var store: UsageStore

    var body: some View {
        ProviderSettingsGroup(provider: provider, store: store) {
            Text("Jules usage is tracked via the `jules` CLI.")
                .font(.callout)
                .foregroundColor(.secondary)
        }
    }
}

struct JulesLoginView: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("To use Jules, you must be logged in via the CLI.")
            Text("Run `jules login` in your terminal.")
                .font(.system(.body, design: .monospaced))
                .padding(8)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(6)

            Button("Check Status") {
                // Trigger a refresh somehow, or just let the user know to wait for the next poll
            }
        }
        .padding()
    }
}
