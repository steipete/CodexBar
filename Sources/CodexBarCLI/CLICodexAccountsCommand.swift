import CodexBarCore
import Commander
import Foundation

extension CodexBarCLI {
    static func codexAccountsCommandDescriptor() -> CommandDescriptor {
        CommandDescriptor(
            name: "codex-accounts",
            abstract: "List, import, or promote managed Codex accounts",
            discussion: nil,
            signature: CommandSignature(),
            subcommands: [
                CommandDescriptor(
                    name: "list",
                    abstract: "List managed accounts without credential contents",
                    discussion: nil,
                    signature: CommandSignature.describe(ConfigOptions()).flattened()),
                CommandDescriptor(
                    name: "promote",
                    abstract: "Explicitly replace system auth after preserving its account",
                    discussion: nil,
                    signature: CommandSignature.describe(CodexAccountPromoteOptions()).flattened()),
                CommandDescriptor(
                    name: "import",
                    abstract: "Copy an existing OAuth profile's auth.json into a new managed account",
                    discussion: nil,
                    signature: CommandSignature.describe(CodexAccountImportOptions()).flattened()),
            ],
            defaultSubcommandName: "list")
    }

    @MainActor
    static func runCodexAccounts(path: [String], values: ParsedValues) async {
        let output = CLIOutputPreferences.from(values: values)
        #if os(macOS)
        do {
            let store = FileManagedCodexAccountStore()
            let liveHome = CodexHomeScope.ambientHomeURL(env: ProcessInfo.processInfo.environment)
            if path == ["codex-accounts", "list"] {
                let rows = try Self.codexAccountRows(
                    accounts: store.loadAccounts().accounts,
                    liveHome: liveHome,
                    reader: DefaultCodexAuthMaterialReader())
                if output.format == .json {
                    Self.printJSON(rows, pretty: output.pretty)
                } else {
                    for row in rows {
                        print("\(row.isSystemAccount ? "*" : " ") \(row.id) \(row.email)")
                    }
                }
                return
            }
            if path == ["codex-accounts", "import"] {
                guard let raw = values.options["fromHome"]?.last, !raw.isEmpty else {
                    throw CodexAccountCLIError.missingImportHome
                }
                let receipt = try Self.importCodexProfile(
                    fromRawHome: raw, store: store, homeFactory: CLICodexManagedHomeFactory())
                if output.format == .json { Self.printJSON(receipt, pretty: output.pretty) } else {
                    let action = receipt.outcome == "imported" ? "Imported" : "Already imported:"
                    print("\(action) \(receipt.id) \(receipt.email). System authentication was not changed.")
                }
                return
            }
            guard path == ["codex-accounts", "promote"], let selector = values.positional.first else {
                throw CodexAccountCLIError.missingSelector
            }
            let transaction = CodexAccountPromotionTransaction(
                store: store,
                homeFactory: CLICodexManagedHomeFactory(),
                authMaterialReader: DefaultCodexAuthMaterialReader(),
                liveAuthSwapper: DefaultCodexLiveAuthSwapper(),
                baseEnvironment: ProcessInfo.processInfo.environment)
            let result = try await transaction.promoteManagedAccount(resolveTargetID: { accounts in
                try Self.resolveCodexAccount(selector: selector, accounts: accounts).id
            })
            let receipt = CodexAccountPromotionReceipt(
                id: result.targetManagedAccountID.uuidString, changedSystemAuth: result.didMutateLiveAuth)
            if output.format == .json { Self.printJSON(receipt, pretty: output.pretty) } else {
                let action = result.didMutateLiveAuth ? "Promoted" : "Already system account:"
                print(
                    "\(action) \(result.targetManagedAccountID.uuidString). "
                        + "Existing Codex processes may retain their current account.")
            }
        } catch {
            Self.exit(code: .failure, message: error.localizedDescription, output: output, kind: .runtime)
        }
        #else
        Self.exit(
            code: .failure,
            message: "Managed Codex account commands are only available on macOS.",
            output: output,
            kind: .args)
        #endif
    }

    /// Imports an existing profile home's OAuth credentials; never changes system authentication.
    static func importCodexProfile(
        fromRawHome raw: String,
        store: any ManagedCodexAccountStoring,
        homeFactory: any ManagedCodexHomeProducing,
        reader: any CodexAuthMaterialReading = CodexImportSourceAuthReader()) throws -> CodexAccountImportReceipt
    {
        let home = try CodexManagedAccountImportTransaction.validateRawSourcePath(raw)
        let result = try CodexManagedAccountImportTransaction(
            store: store, homeFactory: homeFactory, authMaterialReader: reader)
            .importProfile(fromHome: home)
        return CodexAccountImportReceipt(
            id: result.id.uuidString, email: result.email, outcome: result.outcome.rawValue)
    }

    static func resolveCodexAccount(selector: String, accounts: [ManagedCodexAccount]) throws -> ManagedCodexAccount {
        let normalized = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = UUID(uuidString: normalized)
        let matches = accounts.filter {
            id == nil ? $0.email.caseInsensitiveCompare(normalized) == .orderedSame : $0.id == id
        }
        guard matches.count == 1, let account = matches.first else {
            throw matches.isEmpty ? CodexAccountCLIError.unknownAccount : CodexAccountCLIError.ambiguousAccount
        }
        return account
    }

    @MainActor
    static func codexAccountRows(
        accounts: [ManagedCodexAccount],
        liveHome: URL,
        reader: any CodexAuthMaterialReading) -> [CodexAccountListRow]
    {
        func inspect(_ home: URL) -> CodexAuthBackedAccount? {
            guard let data = try? reader.readAuthData(homeURL: home) else { return nil }
            return try? PreparedPromotionContextBuilder.runtimeAccount(from: data)
        }
        var runtimeAccounts: [UUID: CodexAuthBackedAccount] = [:]
        for account in accounts {
            runtimeAccounts[account.id] = inspect(URL(fileURLWithPath: account.managedHomePath, isDirectory: true))
        }
        return Self.codexAccountRows(accounts: accounts, live: inspect(liveHome), runtimeAccounts: runtimeAccounts)
    }

    static func codexAccountRows(
        accounts: [ManagedCodexAccount],
        live: CodexAuthBackedAccount?,
        runtimeAccounts: [UUID: CodexAuthBackedAccount] = [:]) -> [CodexAccountListRow]
    {
        accounts.map { account in
            CodexAccountListRow(id: account.id.uuidString, email: account.email, isSystemAccount: live.flatMap { live in
                runtimeAccounts[account.id].map { runtime in
                    let identity = account.effectiveWorkspaceAccountID.map { CodexIdentity.providerAccount(id: $0) }
                        ?? runtime.identity
                    return CodexIdentityMatcher.matches(
                        identity,
                        lhsEmail: runtime.email,
                        live.identity,
                        rhsEmail: live.email)
                }
            } ?? false)
        }
    }
}

struct CodexAccountPromoteOptions: CommanderParsable {
    @OptionGroup var common: CLICommonOptions
    @Argument(help: "Exact managed account UUID or unambiguous email") var account: String = ""
}

struct CodexAccountImportOptions: CommanderParsable {
    @OptionGroup var common: CLICommonOptions
    @Option(name: .long("from-home"), help: "Absolute path of an existing Codex profile home containing auth.json")
    var fromHome: String?
}

struct CodexAccountImportReceipt: Encodable, Equatable {
    let id: String
    let email: String
    let outcome: String
}

struct CodexAccountListRow: Encodable {
    let id: String
    let email: String
    let isSystemAccount: Bool
}

private struct CodexAccountPromotionReceipt: Encodable {
    let id: String
    let changedSystemAuth: Bool
}

enum CodexAccountCLIError: Error, LocalizedError, Equatable {
    case missingImportHome, missingSelector, unknownAccount, ambiguousAccount, unsafeHome
    var errorDescription: String? {
        switch self {
        case .missingImportHome: "Provide --from-home with an absolute profile home path."
        case .missingSelector: "Provide a managed account UUID or email."
        case .unknownAccount: "No matching managed Codex account."
        case .ambiguousAccount: "Several managed accounts share that email. Use an exact UUID."
        case .unsafeHome: "Managed account home is outside the managed home directory."
        }
    }
}

private struct CLICodexManagedHomeFactory: ManagedCodexHomeProducing {
    private var root: URL {
        FileManagedCodexAccountStore.defaultURL().deletingLastPathComponent()
            .appendingPathComponent("managed-codex-homes", isDirectory: true)
    }

    func makeHomeURL() -> URL { self.root.appendingPathComponent(UUID().uuidString, isDirectory: true) }
    func validateManagedHomeForDeletion(_ url: URL) throws {
        guard url.standardizedFileURL.path.hasPrefix(self.root.standardizedFileURL.path + "/") else {
            throw CodexAccountCLIError.unsafeHome
        }
    }
}
