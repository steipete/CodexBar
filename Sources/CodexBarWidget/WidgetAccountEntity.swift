import AppIntents
import CodexBarCore

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
