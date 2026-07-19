import CodexBarCore
import Foundation

enum CLIClaudeSwapText {
    static let labelScalarLimit = 256
    static let diagnosticScalarLimit = 512

    static func sanitizeLabel(_ text: String) -> String {
        self.sanitize(text, scalarLimit: self.labelScalarLimit)
    }

    static func sanitizeDiagnostic(_ text: String) -> String {
        self.sanitize(text, scalarLimit: self.diagnosticScalarLimit)
    }

    private enum EscapeState {
        case plain
        case escape
        case controlSequence
        case operatingSystemCommand
        case operatingSystemCommandEscape
    }

    private static func sanitize(_ text: String, scalarLimit: Int) -> String {
        var state = EscapeState.plain
        var scalars: [Unicode.Scalar] = []
        scalars.reserveCapacity(min(text.unicodeScalars.count, scalarLimit))

        for scalar in text.unicodeScalars {
            switch state {
            case .escape:
                if scalar.value == 0x5B {
                    state = .controlSequence
                } else if scalar.value == 0x5D {
                    state = .operatingSystemCommand
                } else if (0x30...0x7E).contains(scalar.value) {
                    state = .plain
                }
            case .controlSequence:
                if (0x40...0x7E).contains(scalar.value) {
                    state = .plain
                }
            case .operatingSystemCommand:
                if scalar.value == 0x07 {
                    state = .plain
                } else if scalar.value == 0x1B {
                    state = .operatingSystemCommandEscape
                }
            case .operatingSystemCommandEscape:
                state = scalar.value == 0x5C ? .plain : .operatingSystemCommand
            case .plain:
                switch scalar.value {
                case 0x0A, 0x0D, 0x2028, 0x2029:
                    scalars.append(" ")
                case 0x1B:
                    state = .escape
                case 0x9B:
                    state = .controlSequence
                case 0x9D:
                    state = .operatingSystemCommand
                default:
                    let category = scalar.properties.generalCategory
                    if category != .control, category != .format {
                        scalars.append(scalar)
                    }
                }
            }
        }

        return String(String.UnicodeScalarView(scalars.prefix(scalarLimit)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct CLIClaudeSwapCardsRenderOptions: Sendable {
    let status: ProviderStatusPayload?
    let useColor: Bool
    let resetStyle: ResetTimeDisplayStyle
    let weeklyWorkDays: Int?
    let now: Date
}

enum CLIClaudeSwapCards {
    typealias AccountListReader = @Sendable (String) async throws -> ClaudeSwapAccountList
    typealias AmbientFetch = @Sendable () async -> UsageCommandOutput

    static func executablePath(from config: ProviderConfig?) -> String {
        config?.sanitizedClaudeSwapExecutablePath ?? ""
    }

    static func isEligible(
        provider: UsageProvider,
        integrationEnabled: Bool,
        hasExplicitAccountSelection: Bool,
        sourceModeOverride: ProviderSourceMode?) -> Bool
    {
        provider == .claude
            && integrationEnabled
            && !hasExplicitAccountSelection
            && (sourceModeOverride == nil || sourceModeOverride == .auto)
    }

    static func fetch(
        eligible: Bool,
        executablePath: String,
        showSingleAccount: Bool = false,
        renderOptions: CLIClaudeSwapCardsRenderOptions,
        ambientFetch: @escaping AmbientFetch) async -> UsageCommandOutput
    {
        await self.fetch(
            eligible: eligible,
            executablePath: executablePath,
            showSingleAccount: showSingleAccount,
            renderOptions: renderOptions,
            ambientFetch: ambientFetch,
            accountListReader: { path in
                try await ClaudeSwapAccountReader.readAccountList(executablePath: path)
            })
    }

    static func fetch(
        eligible: Bool,
        executablePath: String,
        showSingleAccount: Bool = false,
        renderOptions: CLIClaudeSwapCardsRenderOptions,
        ambientFetch: @escaping AmbientFetch,
        accountListReader: @escaping AccountListReader) async -> UsageCommandOutput
    {
        guard eligible else { return await ambientFetch() }

        do {
            let list = try await accountListReader(executablePath)
            let accounts = ClaudeSwapAccountProjection.accountSnapshots(from: list, now: renderOptions.now)
            guard ClaudeSwapAccountProjection.shouldPresentAccounts(
                accountCount: accounts.count,
                showSingleAccount: showSingleAccount)
            else { return await ambientFetch() }

            var output = UsageCommandOutput()
            output.cards = accounts.map { account in
                CLICardsRenderer.makeClaudeSwapCard(
                    account: account,
                    renderOptions: renderOptions)
            }
            return output
        } catch {
            var output = await ambientFetch()
            let diagnostic = CLIClaudeSwapText.sanitizeDiagnostic(error.localizedDescription)
            let message = diagnostic.isEmpty ? "claude-swap list failed." : diagnostic
            output.cardFailures.append(CLICardFailure(
                provider: .claude,
                accountLabel: ClaudeSwapAccountProjection.sourceLabel,
                message: message))
            output.exitCode = .failure
            return output
        }
    }
}
