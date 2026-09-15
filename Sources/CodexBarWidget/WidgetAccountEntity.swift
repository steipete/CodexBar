import AppIntents
import CodexBarCore

struct WidgetAccountEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Account")
    static let defaultQuery = WidgetAccountQuery()

    let id: String
    let label: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(self.label)")
    }
}

struct WidgetAccountQuery: EntityQuery {
    @IntentParameterDependency<AccountUsageSelectionIntent>(\.$provider)
    var intent

    func entities(for identifiers: [String]) async throws -> [WidgetAccountEntity] {
        let accounts = WidgetSnapshotStore.load()?.accounts ?? []
        return identifiers.map { id in
            // Keep unavailable references resolvable without restoring a previous private label.
            WidgetAccountEntity(id: id, label: accounts.first { $0.id == id }?.label ?? "Unavailable account")
        }
    }

    func suggestedEntities() async throws -> [WidgetAccountEntity] {
        let provider = self.intent?.provider.provider.instanceID
        return (WidgetSnapshotStore.load()?.accounts ?? [])
            .filter { provider == nil || $0.provider == provider }
            .map { WidgetAccountEntity(id: $0.id, label: $0.label) }
    }
}
