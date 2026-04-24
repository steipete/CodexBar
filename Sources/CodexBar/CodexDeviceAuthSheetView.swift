import AppKit
import CodexBarCore
import SwiftUI

/// Sheet presented while a Codex device-auth flow is in progress.
///
/// Observes `CodexDeviceAuthSession.phase` and shows the user code, a link
/// to auth.openai.com, and a status line. Tapping the user code copies it
/// to the clipboard. Auto-dismisses when the coordinator clears
/// `activeDeviceAuthSession`.
@MainActor
struct CodexDeviceAuthSheetView: View {
    @Bindable var session: CodexDeviceAuthSession

    @State private var copiedAt: Date?

    var body: some View {
        VStack(spacing: 16) {
            Text("Sign in to Codex")
                .font(.title2.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("Open the link and enter this code on any device to finish signing in.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            self.contentArea
                .frame(maxWidth: .infinity)

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Cancel") {
                    self.session.cancel()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 420, height: 320)
    }

    @ViewBuilder
    private var contentArea: some View {
        switch self.session.phase {
        case .requestingCode:
            VStack(spacing: 12) {
                ProgressView()
                Text("Requesting device code…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case let .awaitingUser(userCode, verificationURL):
            self.awaitingUserContent(userCode: userCode, verificationURL: verificationURL)

        case .exchangingTokens:
            VStack(spacing: 12) {
                ProgressView()
                Text("Finishing sign-in…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case let .failed(message):
            VStack(spacing: 8) {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func awaitingUserContent(userCode: String, verificationURL: URL) -> some View {
        VStack(spacing: 14) {
            Button {
                self.copyToPasteboard(userCode)
            } label: {
                HStack(spacing: 10) {
                    Text(userCode)
                        .font(.system(.largeTitle, design: .monospaced).weight(.bold))
                        .tracking(4)
                    Image(systemName: "doc.on.doc")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Copy code to clipboard")

            Text("Copied!")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .opacity(self.copiedAt == nil ? 0 : 1)
                .animation(.easeInOut(duration: 0.18), value: self.copiedAt)

            Link("Open auth.openai.com", destination: verificationURL)
                .font(.subheadline)

            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Waiting for you to sign in…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func copyToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        let stamp = Date()
        self.copiedAt = stamp
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if self.copiedAt == stamp {
                self.copiedAt = nil
            }
        }
    }
}
