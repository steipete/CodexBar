/// Display-only identity. Keep original names and paths for grouping, row IDs, and stored history.
struct CostHistoryIdentity: Equatable {
    let name: String
    let path: String?

    init(name: String, path: String?, placeholder: String, hidePersonalInfo: Bool) {
        self.name = hidePersonalInfo ? placeholder : name
        self.path = hidePersonalInfo ? nil : path
    }
}

extension SpendDashboardModel.ProjectRow {
    func displayIdentity(hidePersonalInfo: Bool) -> CostHistoryIdentity {
        CostHistoryIdentity(
            name: self.projectName,
            path: self.path,
            placeholder: L("Project %d", self.rank),
            hidePersonalInfo: hidePersonalInfo)
    }
}

extension SpendDashboardModel.SessionRow {
    /// Thread names and project folders are personal; the short session ID is the masked label.
    func displayIdentity(hidePersonalInfo: Bool) -> CostHistoryIdentity {
        let fallbackName = L("Session %@", CostHistoryChartMenuView.shortSessionID(self.sessionID))
        return CostHistoryIdentity(
            name: self.title ?? fallbackName,
            path: self.projectPath,
            placeholder: fallbackName,
            hidePersonalInfo: hidePersonalInfo)
    }

    func displaySubtitle(hidePersonalInfo: Bool) -> String {
        let projectName = hidePersonalInfo ? nil : self.projectName
        let date = SpendActivityDateFormatting.mediumDateString(self.lastActivity)
        return [projectName, self.modelName, date].compactMap(\.self).joined(separator: " · ")
    }
}
