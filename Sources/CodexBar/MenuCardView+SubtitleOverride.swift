import Foundation

extension UsageMenuCardView.Model {
    /// Replaces the subtitle with transient status such as an account switch in progress. The text must already
    /// honor Hide Personal Info; it is shown as given, in the requested style. The card stops following the live
    /// refresh monitor's provider status so the override is what renders.
    func applyingSubtitle(text: String, style: SubtitleStyle) -> Self {
        var projected = self
        projected.subtitleText = text
        projected.subtitleStyle = style
        projected.usesLiveSubtitle = false
        return projected
    }

    /// Applies System account switch feedback without hiding an error the card already shows, such as a switch
    /// error published before the switch finishes reconciling.
    func applyingSwitchFeedback(_ feedback: SystemAccountSwitchFeedback.Subtitle?) -> Self {
        guard let feedback else { return self }
        if self.subtitleStyle == .error, feedback.style != .error {
            return self
        }
        return self.applyingSubtitle(text: feedback.text, style: feedback.style)
    }
}
