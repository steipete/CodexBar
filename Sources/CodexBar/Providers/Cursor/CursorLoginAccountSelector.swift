import AppKit
import Foundation

enum CursorLoginAccountSelector {
    /// Metadata presented to the user. Session cookies and headers must never enter this model.
    struct Candidate: Equatable, Sendable {
        let selectionID: String
        let name: String?
        let email: String?
        let sourceLabel: String
    }

    struct Choice: Equatable, Sendable {
        let selectionID: String
        let displayLabel: String
    }

    typealias Chooser = @MainActor ([Choice]) -> String?

    static func choices(for candidates: [Candidate]) -> [Choice] {
        let labeledCandidates = candidates
            .map { candidate in
                (candidate: candidate, baseLabel: self.baseDisplayLabel(for: candidate))
            }
            .sorted { lhs, rhs in
                let lhsLabel = lhs.baseLabel.lowercased()
                let rhsLabel = rhs.baseLabel.lowercased()
                if lhsLabel != rhsLabel {
                    return lhsLabel < rhsLabel
                }
                return lhs.candidate.selectionID < rhs.candidate.selectionID
            }
        let labelCounts = Dictionary(grouping: labeledCandidates, by: { $0.baseLabel }).mapValues(\.count)
        var labelOrdinals: [String: Int] = [:]

        return labeledCandidates
            .map { labeled in
                let displayLabel: String
                if labelCounts[labeled.baseLabel, default: 0] > 1 {
                    let ordinal = labelOrdinals[labeled.baseLabel, default: 0] + 1
                    labelOrdinals[labeled.baseLabel] = ordinal
                    displayLabel = "\(labeled.baseLabel) · \(ordinal)"
                } else {
                    displayLabel = labeled.baseLabel
                }
                return Choice(
                    selectionID: labeled.candidate.selectionID,
                    displayLabel: displayLabel)
            }
    }

    static func selectedCandidateID(
        from choices: [Choice],
        selectedIndex: Int?,
        confirmed: Bool) -> String?
    {
        guard confirmed,
              let selectedIndex,
              choices.indices.contains(selectedIndex)
        else {
            return nil
        }
        return choices[selectedIndex].selectionID
    }

    @MainActor
    static func selectCandidateID(
        from candidates: [Candidate],
        chooser: Chooser = { choices in
            CursorLoginAccountSelector.presentChooser(for: choices)
        }) -> String?
    {
        let choices = self.choices(for: candidates)
        guard !choices.isEmpty,
              let selectedID = chooser(choices),
              choices.contains(where: { $0.selectionID == selectedID })
        else {
            return nil
        }
        return selectedID
    }

    private static func baseDisplayLabel(for candidate: Candidate) -> String {
        var components: [String] = []
        if let name = self.normalized(candidate.name) {
            components.append(name)
        }
        if let email = self.normalized(candidate.email), !components.contains(email) {
            components.append(email)
        }
        if components.isEmpty {
            components.append(L("Account"))
        }
        components.append(candidate.sourceLabel)
        return components.joined(separator: " · ")
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    @MainActor
    private static func presentChooser(for choices: [Choice]) -> String? {
        let popup = NSPopUpButton(
            frame: NSRect(x: 0, y: 0, width: 360, height: 26),
            pullsDown: false)
        for choice in choices {
            popup.addItem(withTitle: choice.displayLabel)
            popup.lastItem?.representedObject = choice.selectionID
        }
        popup.selectItem(at: 0)

        let alert = NSAlert()
        alert.messageText = L("Choose Cursor account")
        alert.informativeText = L("Choose which Cursor account CodexBar should use.")
        alert.alertStyle = .informational
        alert.accessoryView = popup
        alert.addButton(withTitle: L("Use Account"))
        alert.addButton(withTitle: L("Cancel"))

        let confirmed = alert.runModal() == .alertFirstButtonReturn
        return self.selectedCandidateID(
            from: choices,
            selectedIndex: popup.indexOfSelectedItem,
            confirmed: confirmed)
    }
}
