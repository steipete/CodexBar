import Foundation

/// Display-only identity. Keep original names and paths for grouping, row IDs, and stored history.
struct CostHistoryIdentity: Equatable {
    let name: String
    let path: String?

    init(name: String, path: String?, placeholder: String, hidePersonalInfo: Bool) {
        self.name = hidePersonalInfo ? placeholder : name
        self.path = hidePersonalInfo ? nil : path
    }

    init(sessionID: String, title: String?, path: String? = nil, hidePersonalInfo: Bool) {
        let fallbackName = L("Session %@", CostHistoryChartMenuView.shortSessionID(sessionID))
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(
            name: title.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName,
            path: path,
            placeholder: fallbackName,
            hidePersonalInfo: hidePersonalInfo)
    }
}

extension SpendDashboardModel.ProjectRow {
    func displayIdentity(hidePersonalInfo: Bool) -> CostHistoryIdentity {
        let name: String = if self.isProjectless {
            switch self.projectName.trimmingCharacters(in: .whitespacesAndNewlines) {
            case "", "Independent chat": L("Independent chat")
            case "Independent chats": L("Independent chats")
            default: self.projectName
            }
        } else {
            self.projectName
        }
        return CostHistoryIdentity(
            name: name,
            path: self.path,
            placeholder: self.isProjectless ? L("Chat %d", self.rank) : L("Project %d", self.rank),
            hidePersonalInfo: hidePersonalInfo)
    }

    func needsPathDisambiguation(in rows: [Self]) -> Bool {
        let name = self.displayIdentity(hidePersonalInfo: false).name
        return rows.contains {
            $0.id != self.id && $0.isProjectless == self.isProjectless
                && $0.displayIdentity(hidePersonalInfo: false).name == name
        }
    }
}

extension SpendDashboardModel.SessionRow {
    /// Thread names and project folders are personal; the short session ID is the masked label.
    func displayIdentity(hidePersonalInfo: Bool) -> CostHistoryIdentity {
        CostHistoryIdentity(
            sessionID: self.sessionID,
            title: self.title,
            path: self.projectPath,
            hidePersonalInfo: hidePersonalInfo)
    }

    func displaySubtitle(hidePersonalInfo: Bool, calendar: Calendar) -> String {
        let projectName = hidePersonalInfo ? nil : self.projectName
        let date = SpendActivityDateFormatting.mediumDateString(self.lastActivity, calendar: calendar)
        return [projectName, self.modelName, date].compactMap(\.self).joined(separator: " · ")
    }
}
