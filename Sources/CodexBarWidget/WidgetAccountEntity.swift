import AppIntents
import CodexBarCore
import WidgetKit

struct WidgetAccountEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Account")
    static let defaultQuery = WidgetAccountQuery()

    let id: String

    var displayRepresentation: DisplayRepresentation {
        // Resolve labels afresh so a saved intent cannot restore identity hidden by current privacy settings.
        DisplayRepresentation(title: "\(self.displayLabel(in: WidgetSnapshotStore.load()))")
    }

    func displayLabel(in snapshot: WidgetSnapshot?) -> String {
        snapshot?.account(id: self.id)?.label ?? "Unavailable account"
    }
}

struct WidgetAccountQuery: EntityQuery {
    @IntentParameterDependency<AccountUsageSelectionIntent>(\.$provider)
    var intent

    func entities(for identifiers: [String]) async throws -> [WidgetAccountEntity] {
        identifiers.map { id in
            WidgetAccountEntity(id: id)
        }
    }

    func suggestedEntities() async throws -> [WidgetAccountEntity] {
        Self.suggestedEntities(in: WidgetSnapshotStore.load(), provider: self.intent?.provider.provider.instanceID)
    }

    static func suggestedEntities(
        in snapshot: WidgetSnapshot?,
        provider: ProviderInstanceID?) -> [WidgetAccountEntity]
    {
        (snapshot?.accounts ?? [])
            .filter { snapshot?.account(id: $0.id, provider: provider) != nil }
            .map { WidgetAccountEntity(id: $0.id) }
    }
}

/// Browses the Accounts widget; it never switches the application's authenticated account.
struct BrowseWidgetAccountIntent: AppIntent {
    static let title: LocalizedStringResource = "Browse Inactive Account"
    static let description = IntentDescription("Show another inactive account in the Accounts widget.")

    @Parameter(title: "Provider")
    var provider: ProviderChoice

    @Parameter(title: "Account ID")
    var accountID: String

    init() {}

    init(provider: ProviderChoice, accountID: String) {
        self.provider = provider
        self.accountID = accountID
    }

    func perform() async throws -> some IntentResult {
        guard let snapshot = WidgetSnapshotStore.load(),
              WidgetAccountPager.canSelect(
                  accountID: self.accountID, provider: self.provider.provider, snapshot: snapshot)
        else { return .result() }
        WidgetSelectionStore.saveSelectedAccount(self.accountID, for: self.provider.provider)
        WidgetCenter.shared.reloadTimelines(ofKind: "CodexBarAccountsWidget")
        return .result()
    }
}
