import Foundation

#if os(macOS) || os(Linux)
extension CursorStatusProbe {
    func parseUsageSummary(
        _ summary: CursorUsageSummary,
        userInfo: CursorUserInfo?,
        rawJSON: String?,
        requestUsage: CursorUsageResponse? = nil,
        sandUsage: CursorSandUsageStatus? = nil,
        identityFallback: CursorSessionIdentity? = nil,
        teamBudget: CursorTeamSpend.Budget? = nil) -> CursorStatusSnapshot
    {
        let teamBudget = summary.isTeamPlan ? teamBudget : nil
        let billingCycleStart = ISO8601DateParser.parse(summary.billingCycleStart)
        let billingCycleEnd = ISO8601DateParser.parse(summary.billingCycleEnd)

        // Convert cents to USD (plan percent derives from raw values to avoid percent unit mismatches).
        // Use plan.limit directly - breakdown.total represents total *used* credits, not the limit.
        let planUsedRaw = Double(summary.individualUsage?.plan?.used ?? 0)
        let planLimitRaw = Double(summary.individualUsage?.plan?.limit ?? 0)
        func normPct(_ value: Double?) -> Double? {
            guard let v = value else { return nil }
            return UsagePercent(raw: v).displayClamped
        }

        // Cursor's usage-summary percent fields are already in percentage units, even when they are fractional
        // values below 1.0 (for example 0.36 means 0.36%, which the dashboard rounds to 0%).
        let autoPercent = teamBudget == nil ? normPct(summary.individualUsage?.plan?.autoPercentUsed) : nil
        let apiPercent = teamBudget == nil ? normPct(summary.individualUsage?.plan?.apiPercentUsed) : nil

        // Enterprise / team-member personal cap (cents). Reported under `individualUsage.overall` for accounts
        // that don't get a `plan` block. Falls through to existing logic when absent so non-enterprise paths
        // are untouched.
        let overallUsedRaw = (summary.individualUsage?.overall?.used).map(Double.init)
        let overallLimitRaw = (summary.individualUsage?.overall?.limit).map(Double.init)

        // Shared team/enterprise pool (cents). Last-resort fallback when no individual data is available.
        let pooledUsedRaw = (summary.teamUsage?.pooled?.used).map(Double.init)
        let pooledLimitRaw = (summary.teamUsage?.pooled?.limit).map(Double.init)

        // Verified member budgets take precedence; otherwise retain summary percentages and cap fallbacks.
        let planPercentUsed: Double = if let teamBudget {
            UsagePercent(used: teamBudget.usedUSD, limit: teamBudget.limitUSD).displayClamped
        } else if let totalPercentUsed = summary.individualUsage?.plan?.totalPercentUsed {
            UsagePercent(raw: totalPercentUsed).displayClamped
        } else if let autoUsed = autoPercent, let apiUsed = apiPercent {
            UsagePercent(raw: (autoUsed + apiUsed) / 2).displayClamped
        } else if let apiUsed = apiPercent {
            UsagePercent(raw: apiUsed).displayClamped
        } else if let autoUsed = autoPercent {
            UsagePercent(raw: autoUsed).displayClamped
        } else if planLimitRaw > 0 {
            UsagePercent(used: planUsedRaw, limit: planLimitRaw).displayClamped
        } else if let used = overallUsedRaw, let limit = overallLimitRaw, limit > 0 {
            UsagePercent(used: used, limit: limit).displayClamped
        } else if let used = pooledUsedRaw, let limit = pooledLimitRaw, limit > 0 {
            UsagePercent(used: used, limit: limit).displayClamped
        } else {
            0
        }

        // USD figures: prefer the source the headline ultimately came from. When `plan` is missing but
        // `overall` or `pooled` carry the cents, surface those so the on-demand display and downstream
        // consumers see real dollar amounts instead of zeros.
        let planUsed: Double
        let planLimit: Double
        if let teamBudget {
            planUsed = teamBudget.usedUSD
            planLimit = teamBudget.limitUSD
        } else if planLimitRaw > 0 || planUsedRaw > 0 {
            planUsed = planUsedRaw / 100.0
            planLimit = planLimitRaw / 100.0
        } else if let usedCents = overallUsedRaw, let limitCents = overallLimitRaw {
            planUsed = usedCents / 100.0
            planLimit = limitCents / 100.0
        } else if let usedCents = pooledUsedRaw, let limitCents = pooledLimitRaw {
            planUsed = usedCents / 100.0
            planLimit = limitCents / 100.0
        } else {
            planUsed = 0
            planLimit = 0
        }

        let onDemandUsed = Double(summary.individualUsage?.onDemand?.used ?? 0) / 100.0
        let onDemandLimit: Double? = summary.individualUsage?.onDemand?.limit.map { Double($0) / 100.0 }

        let teamOnDemandUsed: Double? = summary.teamUsage?.onDemand?.used.map { Double($0) / 100.0 }
        let teamOnDemandLimit: Double? = summary.teamUsage?.onDemand?.limit.map { Double($0) / 100.0 }

        // Legacy request-based plan: maxRequestUsage being non-nil indicates a request-based plan
        let requestsUsed: Int? = teamBudget == nil
            ? requestUsage?.gpt4?.numRequestsTotal ?? requestUsage?.gpt4?.numRequests : nil
        let requestsLimit: Int? = teamBudget == nil ? requestUsage?.gpt4?.maxRequestUsage : nil

        return CursorStatusSnapshot(
            planPercentUsed: planPercentUsed,
            autoPercentUsed: autoPercent,
            apiPercentUsed: apiPercent,
            planUsedUSD: planUsed,
            planLimitUSD: planLimit,
            onDemandUsedUSD: onDemandUsed,
            onDemandLimitUSD: onDemandLimit,
            teamOnDemandUsedUSD: teamOnDemandUsed,
            teamOnDemandLimitUSD: teamOnDemandLimit,
            billingCycleStart: billingCycleStart,
            billingCycleEnd: billingCycleEnd,
            membershipType: summary.membershipType,
            accountEmail: userInfo?.email ?? identityFallback?.email,
            accountID: userInfo?.sub ?? identityFallback?.subject,
            accountName: userInfo?.name,
            rawJSON: rawJSON,
            sandUsage: sandUsage,
            requestsUsed: requestsUsed,
            requestsLimit: requestsLimit)
    }
}
#endif
