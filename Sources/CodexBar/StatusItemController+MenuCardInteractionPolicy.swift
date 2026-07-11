import CodexBarCore

extension StatusItemController {
    struct MenuCardInteractionPolicy: Equatable {
        let allowsHighlight: Bool
        let forwardsScrollToEmbeddedScrollView: Bool

        static let `default` = Self(allowsHighlight: true, forwardsScrollToEmbeddedScrollView: false)
        static let scrollableContent = Self(allowsHighlight: false, forwardsScrollToEmbeddedScrollView: true)
    }

    static func menuCardInteractionPolicy(for model: UsageMenuCardView.Model) -> MenuCardInteractionPolicy {
        guard model.provider == .cursor,
              let tokenUsage = model.tokenUsage,
              !tokenUsage.cursorRequestDetails.isEmpty
        else {
            return .default
        }
        return .scrollableContent
    }
}
