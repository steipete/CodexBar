import Foundation

extension AntigravityStatusSnapshot {
    static func matchingWindow(
        in windows: [NamedRateWindow],
        for pool: AntigravityPrimaryPoolPreference) -> NamedRateWindow?
    {
        guard pool != .auto else { return nil }
        if let preferredID = pool.preferredQuotaSummaryWindowID,
           let exact = windows.first(where: { $0.usageKnown && $0.id == preferredID })
        {
            return exact
        }
        guard let family = pool.preferredFamily, let minutes = pool.preferredWindowMinutes else { return nil }
        return windows.first {
            $0.usageKnown &&
                AntigravityQuotaFamilyVisibility.knownFamily(windowID: $0.id, title: $0.title) == family &&
                $0.window.windowMinutes == minutes
        }
    }

    public static func reorderedWindows(
        _ windows: [NamedRateWindow],
        primaryPool: AntigravityPrimaryPoolPreference) -> [NamedRateWindow]
    {
        guard primaryPool != .auto,
              let selected = self.matchingWindow(in: windows, for: primaryPool),
              let index = windows.firstIndex(where: { $0.id == selected.id }),
              index > 0
        else { return windows }
        var reordered = windows
        let chosen = reordered.remove(at: index)
        reordered.insert(chosen, at: 0)
        return reordered
    }

    static func subscriptionDates(
        credits: AntigravityCreditsSnapshot?,
        accountMetadata: AntigravityAccountMetadata?,
        accountPlan: String?) -> (renewsAt: Date?, expiresAt: Date?)
    {
        guard let planEnd = credits?.planEnd else { return (nil, nil) }
        let normalizedPlan = accountPlan?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isFreeOrTrialPlan = normalizedPlan == "free" || normalizedPlan == "trial" || normalizedPlan == "starter"
        let isTrialTeams = accountMetadata?.teamsTier?.lowercased().contains("trial") == true
        let isPaid = credits?.topUpStatus?.enabled == true ||
            accountMetadata?.isPro == true ||
            accountMetadata?.g1Tier != nil ||
            (accountMetadata?.teamsTier != nil && !isTrialTeams) ||
            (normalizedPlan != nil && !normalizedPlan!.isEmpty && !isFreeOrTrialPlan)
        return isPaid ? (planEnd, nil) : (nil, planEnd)
    }

    static func detailSections(
        quotaSummary: AntigravityQuotaSummary?,
        catalog: AntigravityCatalogSnapshot? = nil,
        credits: AntigravityCreditsSnapshot?,
        showCredits: Bool) -> [ProviderDetailSection]
    {
        var sections: [ProviderDetailSection] = []
        if showCredits, let credits, let section = Self.creditsDetailSection(from: credits) {
            sections.append(section)
        }
        if let quotaSummary, let availabilitySection = Self.modelAvailabilityDetailSection(from: quotaSummary) {
            sections.append(availabilitySection)
        }
        if let bucketAmounts = catalog?.bucketAmounts,
           let amountSection = Self.bucketAmountDetailSection(from: bucketAmounts)
        {
            sections.append(amountSection)
        }
        if let quotaGroups = catalog?.quotaGroups,
           let groupSection = Self.quotaGroupsDetailSection(from: quotaGroups)
        {
            sections.append(groupSection)
        }
        if let modelCatalog = catalog?.modelCatalog,
           let catalogSection = Self.modelCatalogDetailSection(from: modelCatalog)
        {
            sections.append(catalogSection)
        }
        return Array(sections.prefix(ProviderDetailSection.maximumSectionsPerSnapshot))
    }

    private static func creditsDetailSection(from credits: AntigravityCreditsSnapshot) -> ProviderDetailSection? {
        var rows: [ProviderDetailSection.Row] = []
        if let prompt = credits.prompt,
           let row = Self.creditPoolRow(id: "antigravity-credits-prompt", label: "Prompt credits", pool: prompt)
        {
            rows.append(row)
        }
        if let flow = credits.flow,
           (flow.monthly ?? 0) > 0 || (flow.available ?? 0) > 0 || (flow.used ?? 0) > 0 || (flow.userUsed ?? 0) > 0,
           let row = Self.creditPoolRow(id: "antigravity-credits-flow", label: "Flow credits", pool: flow)
        {
            rows.append(row)
        }
        if let flex = credits.flex,
           flex.available != nil || flex.used != nil || credits.topUpStatus?.enabled == true
        {
            let value = flex.available.map { "\($0) remaining" }
                ?? (credits.topUpStatus?.enabled == true ? "Auto top-up on" : "Available")
            var secondaryParts: [String] = []
            if let used = flex.used {
                secondaryParts.append("\(used) used")
            }
            if credits.topUpStatus?.enabled == true, flex.available != nil {
                secondaryParts.append("Auto top-up on")
            }
            let secondary = secondaryParts.isEmpty ? nil : secondaryParts.joined(separator: " · ")
            rows.append(.makeRow(
                id: "antigravity-credits-flex",
                label: "Flex credits",
                value: value,
                secondaryValue: secondary,
                usageValue: flex.used.map(Double.init)))
        } else if credits.topUpStatus?.enabled == true {
            var secondaryParts: [String] = []
            if let spent = credits.topUpStatus?.spent {
                secondaryParts.append("\(spent) spent")
            }
            if let monthly = credits.topUpStatus?.monthlyAmount {
                secondaryParts.append("\(monthly) monthly cap")
            }
            rows.append(.makeRow(
                id: "antigravity-credits-topup",
                label: "Auto top-up",
                value: "Enabled",
                secondaryValue: secondaryParts.isEmpty ? nil : secondaryParts.joined(separator: " · ")))
        }
        if rows.isEmpty, let tierCredits = credits.availableCredits, !tierCredits.isEmpty {
            for (index, tierCredit) in tierCredits.enumerated() {
                guard let amount = tierCredit.creditAmount else { continue }
                let label = Self.humanizedCreditType(tierCredit.creditType)
                let secondary = tierCredit.minimumCreditAmountForUsage.map { "Min \($0) for usage" }
                rows.append(.makeRow(
                    id: "antigravity-credits-tier-\(index)",
                    label: label,
                    value: "\(amount) remaining",
                    secondaryValue: secondary,
                    usageValue: Double(amount)))
            }
        }
        guard !rows.isEmpty else { return nil }
        return ProviderDetailSection.makeSection(title: "Credits", rows: rows)
    }

    private static func creditPoolRow(
        id: String,
        label: String,
        pool: AntigravityCreditPool) -> ProviderDetailSection.Row?
    {
        guard !pool.isEmpty else { return nil }
        let used = pool.used ?? pool.userUsed
        let value: String
        let progress: ProviderDetailSection.Row.Progress?
        if let available = pool.available, let monthly = pool.monthly, monthly > 0 {
            value = "\(available) / \(monthly)"
            let computedUsed = Double(max(0, monthly - available))
            progress = .makeProgress(used: computedUsed, total: Double(monthly))
        } else if let available = pool.available {
            value = "\(available) remaining"
            progress = nil
        } else if let used, let monthly = pool.monthly, monthly > 0 {
            let remaining = max(0, monthly - used)
            value = "\(remaining) / \(monthly)"
            progress = .makeProgress(used: Double(max(0, used)), total: Double(monthly))
        } else if let used {
            value = "\(used) used"
            progress = nil
        } else {
            return nil
        }
        let secondaryValue = used.map { "\($0) used" }
        return .makeRow(
            id: id,
            label: label,
            value: value,
            secondaryValue: secondaryValue,
            progress: progress,
            usageValue: used.map(Double.init))
    }

    private static func humanizedCreditType(_ raw: String?) -> String {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return "Available credits"
        }
        let lowered = trimmed.lowercased()
        if lowered.contains("google_one") { return "Google One credits" }
        let words = trimmed.split(separator: "_").map { word -> String in
            let lower = word.lowercased()
            if lower == "ai" { return "AI" }
            return lower.prefix(1).uppercased() + lower.dropFirst()
        }
        return words.isEmpty ? "Available credits" : words.joined(separator: " ")
    }

    private static func modelAvailabilityDetailSection(
        from quotaSummary: AntigravityQuotaSummary) -> ProviderDetailSection?
    {
        let nonOperational = quotaSummary.modelAvailabilities
            .filter { _, availability in
                let normalized = Self.normalizedAvailabilityState(availability.state)
                return !normalized.isEmpty &&
                    normalized != "OPERATIONAL" &&
                    normalized != "UNSPECIFIED" &&
                    normalized != "0" &&
                    normalized != "1"
            }
            .sorted { $0.key < $1.key }
        guard !nonOperational.isEmpty else { return nil }
        let rows = nonOperational.prefix(ProviderDetailSection.maximumRowsPerSection).map { modelID, availability in
            ProviderDetailSection.Row.makeRow(
                id: "antigravity-availability-\(modelID)",
                label: Self.humanizedModelID(modelID),
                value: Self.humanizedAvailabilityState(availability.state),
                secondaryValue: availability.explanation)
        }
        return ProviderDetailSection.makeSection(title: "Model availability", rows: rows)
    }

    private static func normalizedAvailabilityState(_ raw: String) -> String {
        let upper = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let prefix = "MODEL_AVAILABILITY_STATE_"
        return upper.hasPrefix(prefix) ? String(upper.dropFirst(prefix.count)) : upper
    }

    private static func humanizedAvailabilityState(_ raw: String) -> String {
        let stripped = Self.normalizedAvailabilityState(raw)
        let words = stripped.split(separator: "_").map { $0.lowercased() }
        guard let first = words.first else { return raw.trimmingCharacters(in: .whitespacesAndNewlines) }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst()).joined(separator: " ")
    }

    private static func bucketAmountDetailSection(
        from bucketAmounts: [AntigravityQuotaBucketAmount]) -> ProviderDetailSection?
    {
        let rows = bucketAmounts.prefix(ProviderDetailSection.maximumRowsPerSection).map { bucket in
            let label = bucket.groupName.map { "\($0) \(bucket.displayName)" } ?? bucket.displayName
            return ProviderDetailSection.Row.makeRow(
                id: "antigravity-amount-\(bucket.bucketId)",
                label: label,
                value: "\(bucket.remainingAmount) remaining",
                usageValue: Double(bucket.remainingAmount))
        }
        guard !rows.isEmpty else { return nil }
        return ProviderDetailSection.makeSection(title: "Bucket amounts", rows: rows)
    }

    private static func quotaGroupsDetailSection(
        from quotaGroups: [AntigravityQuotaGroupRoster]) -> ProviderDetailSection?
    {
        let rows = quotaGroups.prefix(ProviderDetailSection.maximumRowsPerSection).enumerated().map { index, group in
            let value = group.models.isEmpty ? group.description : group.models.joined(separator: ", ")
            return ProviderDetailSection.Row.makeRow(
                id: "antigravity-group-\(index)",
                label: group.displayName,
                value: value)
        }
        guard !rows.isEmpty else { return nil }
        return ProviderDetailSection.makeSection(title: "Quota groups", rows: rows)
    }

    private static func modelCatalogDetailSection(
        from modelCatalog: [AntigravityModelCatalogEntry]) -> ProviderDetailSection?
    {
        let rows = modelCatalog.prefix(ProviderDetailSection.maximumRowsPerSection).map { entry in
            let multiplierText = Self.formattedMultiplier(entry.creditMultiplier)
            let pricingText = Self.humanizedPricingType(entry.pricingType)
            let primaryParts = [multiplierText, pricingText].compactMap(\.self)
            let hasPrimary = !primaryParts.isEmpty
            let tagTitle = entry.tagTitle?.trimmedNonEmpty
            let value = hasPrimary
                ? primaryParts.joined(separator: " · ")
                : (tagTitle ?? (entry.isPremium == true ? "Premium" : "Standard"))
            let secondaryParts = [
                (hasPrimary || tagTitle != nil) && entry.isPremium == true ? "Premium" : nil,
                hasPrimary ? tagTitle : nil,
            ].compactMap(\.self)
            let secondaryValue = secondaryParts.isEmpty ? nil : secondaryParts.joined(separator: " · ")
            return ProviderDetailSection.Row.makeRow(
                id: "antigravity-catalog-\(entry.modelId)",
                label: entry.label,
                value: value,
                secondaryValue: secondaryValue)
        }
        guard !rows.isEmpty else { return nil }
        return ProviderDetailSection.makeSection(title: "Model catalog", rows: rows)
    }

    private static func formattedMultiplier(_ multiplier: Double?) -> String? {
        guard let multiplier, multiplier.isFinite else { return nil }
        if let whole = Int(exactly: multiplier) {
            return "\(whole)×"
        }
        if multiplier.rounded() == multiplier {
            return "\(String(format: "%g", multiplier))×"
        }
        let formatted = String(format: "%.2f", multiplier)
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
        return "\(formatted)×"
    }

    private static func humanizedPricingType(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        let prefix = "MODEL_PRICING_TYPE_"
        let stripped = trimmed.uppercased().hasPrefix(prefix)
            ? String(trimmed.dropFirst(prefix.count))
            : trimmed
        switch stripped.uppercased() {
        case "API":
            return "API"
        case "BYOK":
            return "BYOK"
        case "STATIC_CREDIT":
            return "Static credit"
        default:
            let words = stripped.split(separator: "_").map { $0.lowercased() }
            guard let first = words.first else { return trimmed }
            return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst()).joined(separator: " ")
        }
    }
}

extension AntigravityStatusProbe {
    static func catalogEntry(from config: ModelConfig) -> AntigravityModelCatalogEntry? {
        AntigravityModelCatalogEntry(
            modelId: config.modelOrAlias.model,
            label: config.label,
            creditMultiplier: config.creditMultiplier?.value,
            pricingType: config.pricingType?.rawValue,
            isPremium: config.isPremium,
            tagTitle: config.tagTitle).normalizedIfAttributed
    }

    static func creditsSnapshot(
        from userStatus: UserStatus,
        planInfo: PlanInfo?) -> AntigravityCreditsSnapshot?
    {
        let planStatus = userStatus.planStatus
        let prompt = AntigravityCreditPool(
            available: planStatus?.availablePromptCredits?.value,
            used: planStatus?.usedPromptCredits?.value,
            userUsed: userStatus.userUsedPromptCredits?.value,
            monthly: planInfo?.monthlyPromptCredits?.value)
        let flow = AntigravityCreditPool(
            available: planStatus?.availableFlowCredits?.value,
            used: planStatus?.usedFlowCredits?.value,
            userUsed: userStatus.userUsedFlowCredits?.value,
            monthly: planInfo?.monthlyFlowCredits?.value)
        let flex = AntigravityCreditPool(
            available: planStatus?.availableFlexCredits?.value,
            used: planStatus?.usedFlexCredits?.value)
        let topUp: AntigravityTopUpStatus? = planStatus?.topUpStatus.flatMap { raw in
            let txStatus = Self.nonUnspecifiedEnumValue(raw.topUpTransactionStatus)
            let resolved = AntigravityTopUpStatus(
                enabled: raw.topUpEnabled,
                criteriaMet: raw.topUpCriteriaMet,
                monthlyAmount: raw.monthlyTopUpAmount?.value,
                spent: raw.topUpSpent?.value,
                increment: raw.topUpIncrement?.value,
                transactionStatus: txStatus)
            return resolved.isEmpty ? nil : resolved
        }
        let snapshot = AntigravityCreditsSnapshot(
            prompt: prompt.isEmpty ? nil : prompt,
            flow: flow.isEmpty ? nil : flow,
            flex: flex.isEmpty ? nil : flex,
            monthlyFlexPurchaseAmount: planInfo?.monthlyFlexCreditPurchaseAmount?.value,
            canBuyMoreCredits: planInfo?.canBuyMoreCredits,
            topUpStatus: topUp,
            planStart: planStatus?.planStart.flatMap(Self.parseDate),
            planEnd: planStatus?.planEnd.flatMap(Self.parseDate))
        return snapshot.isEmpty ? nil : snapshot
    }

    static func accountMetadata(
        from userStatus: UserStatus,
        planInfo: PlanInfo?) -> AntigravityAccountMetadata?
    {
        let metadata = AntigravityAccountMetadata(
            g1Tier: userStatus.g1Tier?.trimmedNonEmpty,
            teamsTier: Self.nonUnspecifiedEnumValue(planInfo?.teamsTier),
            isPro: userStatus.pro,
            teamId: userStatus.teamId?.trimmedNonEmpty,
            teamStatus: Self.nonUnspecifiedEnumValue(userStatus.teamStatus))
        return metadata.isEmpty ? nil : metadata
    }

    private static func nonUnspecifiedEnumValue(_ code: CodeValue?) -> String? {
        guard let raw = code?.rawValue.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let upper = raw.uppercased()
        if upper == "0" || upper.hasSuffix("_UNSPECIFIED") {
            return nil
        }
        return raw
    }
}
