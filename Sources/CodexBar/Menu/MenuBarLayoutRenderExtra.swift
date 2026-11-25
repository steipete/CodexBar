import CodexBarCore

struct MenuBarLayoutRenderExtra: Hashable {
    let id: String
    let title: String
    let window: MenuBarLayoutRenderWindow?
    var pace: String?
    var paceDelta: Double?

    init(_ namedWindow: NamedRateWindow) {
        self.id = namedWindow.id
        self.title = namedWindow.title
        self.window = namedWindow.usageKnown ? MenuBarLayoutRenderWindow(namedWindow.window) : nil
    }

    static func signature(tokens: [MenuBarLayoutToken], provider: UsageProvider, snapshot: UsageSnapshot?) -> Int? {
        let ids = Set(tokens.compactMap { token -> String? in
            if case let .extraPercent(id) = token { return id }
            return nil
        })
        guard !ids.isEmpty else { return nil }
        return MenuBarLayoutNamedExtra.windows(provider: provider, snapshot: snapshot)
            .filter { ids.contains($0.id) }.map(Self.init).hashValue
    }
}
