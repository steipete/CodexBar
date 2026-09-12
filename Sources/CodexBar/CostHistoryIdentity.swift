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
