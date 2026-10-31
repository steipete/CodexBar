import Foundation

/// One labelled quota in a plugin's compact menu-bar summary; references existing native window data.
public struct ProviderMenuBarItem: Codable, Sendable {
    public static let maximumItems = 8

    public let title: String
    public let iconProvider: UsageProvider?
    public let windowID: String?

    public init(title: String, iconProvider: UsageProvider? = nil, windowID: String? = nil) throws {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= ProviderDetailSection.maximumStringLength else {
            throw ProviderDetailSection.ValidationError("menuBarItem.title must contain 1–120 characters")
        }
        let windowID = windowID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (windowID?.count ?? 0) <= ProviderDetailSection.maximumStringLength else {
            throw ProviderDetailSection.ValidationError("menuBarItem.windowID exceeds 120 characters")
        }
        self.title = title
        self.iconProvider = iconProvider
        self.windowID = windowID?.isEmpty == false ? windowID : nil
    }

    public func window(in snapshot: UsageSnapshot) -> RateWindow? {
        guard let windowID else { return nil }
        guard let window = snapshot.extraRateWindows?.first(where: { $0.id == windowID && $0.usageKnown })?.window
            .measured,
            window.usedPercent.isFinite else { return nil }
        return window
    }

    private enum CodingKeys: String, CodingKey {
        case title, iconProvider, windowID
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            title: container.decode(String.self, forKey: .title),
            iconProvider: container.decodeIfPresent(UsageProvider.self, forKey: .iconProvider),
            windowID: container.decodeIfPresent(String.self, forKey: .windowID))
    }
}
