import AppKit
import SwiftUI

@MainActor
struct HTTPServerSection: View {
    @Bindable var controller: HTTPServerController
    @State private var showToken = false
    @State private var draft = HTTPServerConfiguration()

    var body: some View {
        Section {
            Toggle(L("http_server_enable"), isOn: self.$draft.enabled)
            TextField(L("http_server_bind"), text: self.$draft.host)
            TextField(L("http_server_port"), value: self.$draft.port, format: .number.grouping(.never))
            HStack {
                if self.showToken {
                    TextField(L("http_server_token"), text: self.$draft.token)
                } else {
                    SecureField(L("http_server_token"), text: self.$draft.token)
                }
                Button(self.showToken ? L("menu_bar_layout_conditional_hide") : L("http_server_show")) {
                    self.showToken.toggle()
                }
                Button(L("http_server_generate")) { self.draft.token = HTTPServerConfiguration.generateToken() }
                Button(L("copy")) { self.copy(self.draft.token) }.disabled(self.draft.token.isEmpty)
            }
            TextField(L("http_server_cache"), value: self.$draft.refreshInterval, format: .number)
            TextField(L("http_server_timeout"), value: self.$draft.requestTimeout, format: .number)
            Toggle(L("http_server_all_accounts"), isOn: self.$draft.allAccounts)
            Picker(L("http_server_identity"), selection: self.$draft.identity) {
                Text(L("http_server_redacted")).tag("redacted")
                Text(L("full").localizedCapitalized).tag("full")
            }
            if !self.draft.isLoopback {
                Text(L("http_server_warning"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle(L("http_server_plain_http"), isOn: self.$draft.allowPlainHTTP)
            }
            LabeledContent(L("Status"), value: self.controller.status)
            if let url = self.controller.runningURL {
                LabeledContent(L("http_server_dashboard")) {
                    Text(url).textSelection(.enabled)
                    Button(L("copy")) { self.copy(url) }
                }
                if self.controller.configuration.bindHost == "0.0.0.0" {
                    Text(L("http_server_wildcard"))
                        .font(.caption)
                }
            }
            Button(L("apply")) {
                Task { await self.controller.apply(self.draft) }
            }
            .disabled(self.controller.isTransitioning)
        } header: {
            Text(L("http_server_title"))
        } footer: {
            Text(L("http_server_footer"))
        }
        .onAppear { self.draft = self.controller.configuration }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
