import CodexBarCore
import Foundation
import SwiftUI

enum RollingWindowAutoStartSupport {
    static let providers: Set<UsageProvider> = [
        .codex,
        .claude,
        .opencode,
    ]

    @MainActor
    static func toggle(context: ProviderSettingsContext) -> ProviderSettingsToggleDescriptor? {
        guard self.providers.contains(context.provider) else { return nil }

        let binding = Binding(
            get: { context.settings.rollingWindowAutoStartEnabled(provider: context.provider) },
            set: { enabled in
                context.settings.setRollingWindowAutoStartEnabled(provider: context.provider, enabled: enabled)
            })

        return ProviderSettingsToggleDescriptor(
            id: "\(context.provider.rawValue)-rolling-window-auto-start",
            title: "Auto-start rolling window",
            subtitle: "When a rolling window expires and provider data shows no active replacement, "
                + "send a tiny prompt through the provider CLI.",
            binding: binding,
            statusText: {
                context.store.rollingWindowAutoStartStatus[context.provider]
            },
            actions: [],
            isVisible: nil,
            onChange: nil,
            onAppDidBecomeActive: nil,
            onAppearWhenEnabled: nil)
    }

    static func rollingWindow(provider: UsageProvider, snapshot: UsageSnapshot) -> RateWindow? {
        guard self.providers.contains(provider) else { return nil }
        return snapshot.primary
    }
}

final class RollingWindowAutoStartRuntimeState {
    var inFlight: Set<UsageProvider> = []
    var attemptedResetAt: [UsageProvider: Date] = [:]
    var testRunnerOverride: (any RollingWindowPingRunning)?
}

struct RollingWindowAutoStartDecision: Equatable {
    let resetAt: Date

    static func shouldStart(
        provider: UsageProvider,
        previous: UsageSnapshot?,
        currentProviderData: UsageSnapshot,
        now: Date = Date()) -> RollingWindowAutoStartDecision?
    {
        guard RollingWindowAutoStartSupport.providers.contains(provider),
              let previousWindow = previous.flatMap({ RollingWindowAutoStartSupport.rollingWindow(
                  provider: provider,
                  snapshot: $0) }),
              let previousResetAt = previousWindow.resetsAt,
              previousResetAt <= now
        else {
            return nil
        }

        let currentWindow = RollingWindowAutoStartSupport.rollingWindow(
            provider: provider,
            snapshot: currentProviderData)
        if let currentResetAt = currentWindow?.resetsAt, currentResetAt > now {
            return nil
        }

        return RollingWindowAutoStartDecision(resetAt: previousResetAt)
    }
}

struct RollingWindowPingRequest: Sendable {
    let provider: UsageProvider
    let binary: String
    let arguments: [String]
    let environment: [String: String]
    let timeout: TimeInterval
    let label: String
}

protocol RollingWindowPingRunning: Sendable {
    func run(_ request: RollingWindowPingRequest) async throws
}

struct SubprocessRollingWindowPingRunner: RollingWindowPingRunning {
    func run(_ request: RollingWindowPingRequest) async throws {
        _ = try await SubprocessRunner.run(
            binary: request.binary,
            arguments: request.arguments,
            environment: request.environment,
            timeout: request.timeout,
            label: request.label)
    }
}

enum RollingWindowPingStarter {
    static let defaultPrompt = "hi"
    static let defaultTimeout: TimeInterval = 90

    static func start(
        provider: UsageProvider,
        environment baseEnvironment: [String: String],
        runner: any RollingWindowPingRunning = SubprocessRollingWindowPingRunner()) async throws
    {
        guard let command = self.command(
            provider: provider,
            environment: baseEnvironment)
        else {
            throw RollingWindowPingError.unsupportedProvider(provider)
        }

        var environment = baseEnvironment
        environment["PATH"] = PathBuilder.effectivePATH(purposes: [.tty, .rpc], env: environment)

        try await runner.run(RollingWindowPingRequest(
            provider: provider,
            binary: command.binary,
            arguments: command.arguments,
            environment: environment,
            timeout: command.timeout,
            label: "rolling-window-auto-start-\(provider.rawValue)"))
    }

    static func command(provider: UsageProvider, environment: [String: String]) -> RollingWindowPingCommand? {
        let prompt = self.value(
            environment: environment,
            key: self.envKey(provider: provider, suffix: "PROMPT")) ?? self.defaultPrompt
        let timeout = self.doubleValue(
            environment: environment,
            key: self.envKey(provider: provider, suffix: "TIMEOUT")) ?? self.defaultTimeout
        let binary = self.value(
            environment: environment,
            key: self.envKey(provider: provider, suffix: "BINARY"))

        switch provider {
        case .codex:
            let model = self.value(environment: environment, key: self.envKey(provider: provider, suffix: "MODEL"))
                ?? "gpt-5.4-mini"
            let reasoning = self.value(
                environment: environment,
                key: self.envKey(provider: provider, suffix: "REASONING")) ?? "low"
            return self.command(
                binary: binary,
                executable: "codex",
                arguments: [
                    "exec",
                    "--skip-git-repo-check",
                    "--ephemeral",
                    "-m",
                    model,
                    "-c",
                    "model_reasoning_effort=\"\(reasoning)\"",
                    prompt,
                ],
                timeout: timeout)
        case .claude:
            let model = self.value(environment: environment, key: self.envKey(provider: provider, suffix: "MODEL"))
                ?? "haiku"
            return self.command(
                binary: binary,
                executable: "claude",
                arguments: ["-p", prompt, "--model", model],
                timeout: timeout)
        case .opencode:
            let model = self.value(environment: environment, key: self.envKey(provider: provider, suffix: "MODEL"))
                ?? "anthropic/claude-3-5-haiku-latest"
            return self.command(
                binary: binary,
                executable: "opencode",
                arguments: ["run", "--model", model, "--variant", "minimal", prompt],
                timeout: timeout)
        default:
            return nil
        }
    }

    private static func command(
        binary: String?,
        executable: String,
        arguments: [String],
        timeout: TimeInterval) -> RollingWindowPingCommand
    {
        if let binary {
            return RollingWindowPingCommand(binary: binary, arguments: arguments, timeout: timeout)
        }
        return RollingWindowPingCommand(binary: "/usr/bin/env", arguments: [executable] + arguments, timeout: timeout)
    }

    private static func envKey(provider: UsageProvider, suffix: String) -> String {
        let normalized = provider.rawValue
            .uppercased()
            .replacingOccurrences(of: "-", with: "_")
        return "CODEXBAR_ROLLING_WINDOW_\(normalized)_\(suffix)"
    }

    private static func value(environment: [String: String], key: String) -> String? {
        let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    private static func doubleValue(environment: [String: String], key: String) -> Double? {
        guard let value = self.value(environment: environment, key: key),
              let parsed = Double(value),
              parsed.isFinite,
              parsed > 0
        else {
            return nil
        }
        return parsed
    }
}

struct RollingWindowPingCommand: Equatable {
    let binary: String
    let arguments: [String]
    let timeout: TimeInterval
}

enum RollingWindowPingError: LocalizedError {
    case unsupportedProvider(UsageProvider)

    var errorDescription: String? {
        switch self {
        case let .unsupportedProvider(provider):
            "\(provider.displayName) does not have a configured rolling-window CLI ping command."
        }
    }
}

extension UsageProvider {
    var displayName: String {
        ProviderDescriptorRegistry.metadata[self]?.displayName ?? self.rawValue
    }
}
