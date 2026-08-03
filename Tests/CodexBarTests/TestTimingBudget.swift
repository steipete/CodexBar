import Foundation

/// Wall-clock assertions in this suite are regression guards, not latency SLOs: they exist to
/// catch algorithmic blowups and hung process teardown, and a shared CI runner executing several
/// test shards in parallel routinely takes multiples of a quiet machine's time for the same work.
/// Scale every timing budget through here so load-induced scheduler noise cannot fail a test that
/// is behaving correctly.
enum TestTimingBudget {
    /// `3` is empirical headroom: the workspace-snapshot budget has been observed at ~1.1x its
    /// limit on a loaded machine, and process-teardown budgets fare worse under contention.
    static let slowdownFactor: Double = isLoadedRunner ? 3 : 1

    static var isLoadedRunner: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["CI"] != nil || environment["GITHUB_ACTIONS"] != nil
    }

    static func scaled(_ budget: Duration) -> Duration {
        budget * self.slowdownFactor
    }
}
