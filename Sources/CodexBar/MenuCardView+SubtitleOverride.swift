import Foundation

extension UsageMenuCardView.Model {
    /// Replaces the subtitle with transient status such as an account switch in progress. The text must already
    /// honor Hide Personal Info; it is shown as given, in the requested style.
    func applyingSubtitle(text: String, style: SubtitleStyle) -> Self {
        var projected = self
        projected.subtitleText = text
        projected.subtitleStyle = style
        return projected
    }
}
