import AppKit
import CodexBarCore
import Observation
import SwiftUI

@MainActor
@Observable
final class QuotaStore {
    let files: QuotaCredentialFiles
    let service: QuotaService
    var windows: [Subscription: [QuotaWindow]] = [:]
    var errors: [Subscription: String] = [:]
    var busy: Set<Subscription> = []
    var deviceCode: String?
    var codexLogin: Task<Void, Never>?

    init() {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codexbar/personal-quotas", isDirectory: true)
        let files = QuotaCredentialFiles(directory: directory, googleStore: AntigravityOAuthCredentialsStore())
        self.files = files
        self.service = QuotaService(credentials: files.credentials)
    }

    func refresh(_ provider: Subscription) async {
        guard self.busy.insert(provider).inserted else { return }
        defer { self.busy.remove(provider) }
        do {
            self.windows[provider] = try await self.service.fetch(provider)
            self.errors[provider] = nil
        } catch {
            self.windows[provider] = nil
            self.errors[provider] = error.localizedDescription
        }
    }

    func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            for provider in Subscription.allCases {
                group.addTask { await self.refresh(provider) }
            }
        }
    }

    func connectCodex() {
        guard self.busy.insert(.codex).inserted else { return }
        self.codexLogin = Task {
            do {
                try await self.service.connectCodex { code in
                    try await self.showDeviceCode(code)
                }
                self.busy.remove(.codex)
                await self.refresh(.codex)
            } catch {
                self.busy.remove(.codex)
                if !Task.isCancelled { self.errors[.codex] = error.localizedDescription }
            }
            self.deviceCode = nil
            self.codexLogin = nil
        }
    }

    private func showDeviceCode(_ code: String) throws {
        self.deviceCode = code
        guard NSWorkspace.shared.open(URL(string: "https://auth.openai.com/codex/device")!) else {
            throw URLError(.cannotLoadFromNetwork)
        }
    }

    func connectGoogle() async {
        guard self.busy.insert(.antigravity).inserted else { return }
        let result = await AntigravityLoginRunner.run()
        self.busy.remove(.antigravity)
        switch result.outcome {
        case .success: await self.refresh(.antigravity)
        case .cancelled: break
        case .timedOut: self.errors[.antigravity] = "Google 登录超时。"
        case let .failed(message), let .launchFailed(message): self.errors[.antigravity] = message
        }
    }

    func disconnect(_ provider: Subscription) {
        guard !self.busy.contains(provider) else { return }
        do {
            try self.files.disconnect(provider)
            self.windows[provider] = nil
            self.errors[provider] = QuotaError.missingCredential.localizedDescription
        } catch {
            self.errors[provider] = error.localizedDescription
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = QuotaStore()
    private var refreshTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_: Notification) {
        self.refreshTask = Task {
            while !Task.isCancelled {
                await self.store.refreshAll()
                do { try await Task.sleep(for: .seconds(300)) } catch { return }
            }
        }
    }

    func applicationWillTerminate(_: Notification) {
        self.refreshTask?.cancel()
    }
}

@main
enum PersonalQuotaMain {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--list-subscriptions") {
            for provider in Subscription.allCases {
                print(provider.rawValue)
            }
            return
        }
        PersonalQuotaApp.main()
    }
}

struct PersonalQuotaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("CodexBar", systemImage: "chart.bar") {
            QuotaMenu(store: self.delegate.store)
        }
        .menuBarExtraStyle(.window)
        Settings {
            QuotaSettings(store: self.delegate.store)
        }
    }
}

/// Shared interactive Google sign-in uses these localized browser completion strings.
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}
