import Foundation

enum ProviderPluginSnapshotMapper {
    private static let maximumStringBytes = 256
    private static let maximumJavaScriptSafeInteger = 9_007_199_254_740_991.0

    private struct CostUsageParsedEntry {
        let date: String
        let inputTokens: Int
        let outputTokens: Int
        let reasoningTokens: Int?
        let requests: Int
        let cost: Double
        let estimatedCost: Double
        let model: String?
    }

    private struct CostUsageAccumulator {
        var inputTokens = 0
        var outputTokens = 0
        var reasoningTokens = 0
        var hasReasoningTokens = false
        var requests = 0
        var cost = 0.0
        var estimatedCost = 0.0
        var estimatedRequests = 0
    }

    private struct CostUsageAggregation {
        let daily: [CostUsageDailyReport.Entry]
        let totalTokens: Int
        let totalRequests: Int
        let totalCost: Double
        let totalEstimatedCost: Double
    }

    static func map(
        _ value: any ProviderPluginValue,
        provider: ProviderInstanceID,
        now: Date = Date()) throws -> UsageSnapshot
    {
        guard value.isObject, !value.isArray, !value.isNull else {
            throw ProviderPluginError.invalidSnapshot("fetchUsage must resolve to an object")
        }

        let primary = try self.window(value, property: "primary")
        let secondary = try self.window(value, property: "secondary")
        let tertiary = try self.window(value, property: "tertiary")
        let extraRateWindows = try self.extraWindows(value)
        let providerCost = try self.cost(value, now: now)
        let costUsage = try self.costUsage(value)
        let details = try self.details(value)
        let identity = try self.identity(value, provider: provider)
        let subscriptionRenewsAt = try self.optionalDate(value, property: "subscriptionRenewsAt")
        let subscriptionExpiresAt = try self.optionalDate(value, property: "subscriptionExpiresAt")
        let dataConfidence = try self.dataConfidence(value)

        guard primary != nil || secondary != nil || tertiary != nil || !(extraRateWindows?.isEmpty ?? true)
            || providerCost != nil
            || costUsage != nil
            || !details.isEmpty
            || self.hasMeaningfulIdentity(identity)
        else {
            throw ProviderPluginError.invalidSnapshot(
                "snapshot must contain at least one rate window, cost, detail section, or identity field")
        }

        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: tertiary,
            extraRateWindows: extraRateWindows,
            providerCost: providerCost,
            costUsage: costUsage,
            details: details,
            subscriptionExpiresAt: subscriptionExpiresAt,
            subscriptionRenewsAt: subscriptionRenewsAt,
            updatedAt: now,
            identity: identity,
            dataConfidence: dataConfidence)
    }

    private static func hasMeaningfulIdentity(_ identity: ProviderIdentitySnapshot?) -> Bool {
        guard let identity else { return false }
        return identity.accountEmail != nil || identity.accountOrganization != nil || identity.loginMethod != nil
            || identity.accountID != nil
    }

    private static func dataConfidence(_ root: any ProviderPluginValue) throws -> UsageDataConfidence {
        guard let value = root.property("dataConfidence"), !value.isUndefined, !value.isNull else {
            return .unknown
        }
        guard value.isString, let confidence = UsageDataConfidence(rawValue: value.stringValue()) else {
            throw ProviderPluginError.invalidSnapshot(
                "dataConfidence must be 'exact', 'estimated', 'percentOnly', or 'unknown'")
        }
        return confidence
    }

    private static func details(_ root: any ProviderPluginValue) throws -> [ProviderDetailSection] {
        guard let value = root.property("details"), !value.isUndefined, !value.isNull else { return [] }
        guard value.isArray else {
            throw ProviderPluginError.invalidSnapshot("details must be an array")
        }
        let count = Int(value.property("length")?.int32Value() ?? 0)
        guard count <= ProviderDetailSection.maximumSectionsPerSnapshot else {
            throw ProviderPluginError.invalidSnapshot(
                "details exceeds \(ProviderDetailSection.maximumSectionsPerSnapshot) sections")
        }
        return try (0..<count).map { index in
            guard let section = value.element(at: index), section.isObject, !section.isArray else {
                throw ProviderPluginError.invalidSnapshot("details[\(index)] must be an object")
            }
            let path = "details[\(index)]"
            let title = try self.optionalDetailString(section, property: "title", path: path)
            guard let rowsValue = section.property("rows"), rowsValue.isArray else {
                throw ProviderPluginError.invalidSnapshot("\(path).rows must be an array")
            }
            let rowCount = Int(rowsValue.property("length")?.int32Value() ?? 0)
            guard rowCount <= ProviderDetailSection.maximumRowsPerSection else {
                throw ProviderPluginError.invalidSnapshot(
                    "\(path).rows exceeds \(ProviderDetailSection.maximumRowsPerSection) entries")
            }
            let rows = try (0..<rowCount).map { rowIndex in
                guard let row = rowsValue.element(at: rowIndex), row.isObject, !row.isArray else {
                    throw ProviderPluginError.invalidSnapshot("\(path).rows[\(rowIndex)] must be an object")
                }
                let rowPath = "\(path).rows[\(rowIndex)]"
                return try ProviderDetailSection.Row(
                    label: self.requiredDetailString(row, property: "label", path: rowPath),
                    value: self.requiredDetailString(row, property: "value", path: rowPath),
                    secondaryValue: self.optionalDetailString(row, property: "secondaryValue", path: rowPath))
            }
            let chart = try self.detailChart(section, path: path)
            return try ProviderDetailSection(title: title, rows: rows, chart: chart)
        }
    }

    private static func detailChart(
        _ section: any ProviderPluginValue,
        path: String) throws -> ProviderDetailSection.Chart?
    {
        guard let chart = section.property("chart"), !chart.isUndefined, !chart.isNull else { return nil }
        guard chart.isObject, !chart.isArray else {
            throw ProviderPluginError.invalidSnapshot("\(path).chart must be an object")
        }
        let chartPath = "\(path).chart"
        let rawKind = try self.requiredDetailString(chart, property: "kind", path: chartPath)
        guard let kind = ProviderDetailSection.Chart.Kind(rawValue: rawKind) else {
            throw ProviderPluginError.invalidSnapshot("\(chartPath).kind must be 'bars' or 'line'")
        }
        let title = try self.optionalDetailString(chart, property: "title", path: chartPath)
        let unit = try self.optionalDetailString(chart, property: "unit", path: chartPath)
        guard let pointsValue = chart.property("points"), pointsValue.isArray else {
            throw ProviderPluginError.invalidSnapshot("\(chartPath).points must be an array")
        }
        let pointCount = Int(pointsValue.property("length")?.int32Value() ?? 0)
        guard pointCount <= ProviderDetailSection.maximumPointsPerChart else {
            throw ProviderPluginError.invalidSnapshot(
                "\(chartPath).points exceeds \(ProviderDetailSection.maximumPointsPerChart) entries")
        }
        let points = try (0..<pointCount).map { pointIndex in
            guard let point = pointsValue.element(at: pointIndex), point.isObject, !point.isArray else {
                throw ProviderPluginError.invalidSnapshot("\(chartPath).points[\(pointIndex)] must be an object")
            }
            let pointPath = "\(chartPath).points[\(pointIndex)]"
            return try ProviderDetailSection.Chart.Point(
                label: self.requiredDetailString(point, property: "label", path: pointPath),
                value: self.requiredFiniteNumber(point, property: "value", path: pointPath))
        }
        return try ProviderDetailSection.Chart(kind: kind, title: title, unit: unit, points: points)
    }

    private static func requiredDetailString(
        _ value: any ProviderPluginValue,
        property: String,
        path: String) throws -> String
    {
        guard let string = try self.optionalDetailString(value, property: property, path: path) else {
            throw ProviderPluginError.invalidSnapshot("\(path).\(property) is required")
        }
        return string
    }

    private static func optionalDetailString(
        _ value: any ProviderPluginValue,
        property: String,
        path: String) throws -> String?
    {
        guard let propertyValue = value.property(property),
              !propertyValue.isUndefined,
              !propertyValue.isNull
        else { return nil }
        guard propertyValue.isString else {
            throw ProviderPluginError.invalidSnapshot("\(path).\(property) must be a string")
        }
        let string = propertyValue.stringValue().trimmingCharacters(in: .whitespacesAndNewlines)
        guard string.count <= ProviderDetailSection.maximumStringLength else {
            throw ProviderPluginError.invalidSnapshot(
                "\(path).\(property) exceeds \(ProviderDetailSection.maximumStringLength) characters")
        }
        return string.isEmpty ? nil : string
    }

    private static func window(_ root: any ProviderPluginValue, property: String) throws -> RateWindow? {
        guard let value = root.property(property), !value.isUndefined, !value.isNull else { return nil }
        return try self.window(value, path: property)
    }

    private static func window(_ value: any ProviderPluginValue, path: String) throws -> RateWindow {
        guard value.isObject, !value.isArray else {
            throw ProviderPluginError.invalidSnapshot("\(path) must be an object")
        }
        let rawPercent = try self.requiredFiniteNumber(value, property: "usedPercent", path: path)
        let usedPercent = min(100, max(0, rawPercent))
        let windowMinutes = try self.optionalPositiveInteger(value, property: "windowMinutes", path: path)
        let resetsAt = try self.optionalDate(value, property: "resetsAt", path: path)
        let resetDescription = try self.optionalString(value, property: "resetDescription", path: path)
        let nextRegenPercent = try self.optionalFiniteNumber(value, property: "nextRegenPercent", path: path)
        return RateWindow(
            usedPercent: usedPercent,
            windowMinutes: windowMinutes,
            resetsAt: resetsAt,
            resetDescription: resetDescription,
            nextRegenPercent: nextRegenPercent.map { min(100, max(0, $0)) })
    }

    private static func extraWindows(_ root: any ProviderPluginValue) throws -> [NamedRateWindow]? {
        guard let value = root.property("extraWindows"), !value.isUndefined, !value.isNull else { return nil }
        guard value.isArray else {
            throw ProviderPluginError.invalidSnapshot("extraWindows must be an array")
        }
        let count = Int(value.property("length")?.int32Value() ?? 0)
        guard count <= 64 else {
            throw ProviderPluginError.invalidSnapshot("extraWindows exceeds 64 entries")
        }
        return try (0..<count).map { index in
            guard let item = value.element(at: index), item.isObject, !item.isArray else {
                throw ProviderPluginError.invalidSnapshot("extraWindows[\(index)] must be an object")
            }
            let path = "extraWindows[\(index)]"
            let id = try self.requiredString(item, property: "id", path: path)
            let title = try self.requiredString(item, property: "title", path: path)
            let windowValue = item.property("window")
            let window = try self.window(
                windowValue?.isObject == true && windowValue?.isNull == false ? windowValue! : item,
                path: "\(path).window")
            return NamedRateWindow(id: id, title: title, window: window)
        }
    }

    private static func cost(_ root: any ProviderPluginValue, now: Date) throws -> ProviderCostSnapshot? {
        guard let value = root.property("cost"), !value.isUndefined, !value.isNull else { return nil }
        guard value.isObject, !value.isArray else {
            throw ProviderPluginError.invalidSnapshot("cost must be an object")
        }
        let used = try self.requiredFiniteNumber(value, property: "used", path: "cost")
        let limit = try self.optionalFiniteNumber(value, property: "limit", path: "cost") ?? 0
        let currency = try self.requiredString(value, property: "currency", path: "cost")
        guard currency.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil else {
            throw ProviderPluginError.invalidSnapshot("cost.currency must be a three-letter uppercase currency literal")
        }
        let period = try self.optionalString(value, property: "period", path: "cost")
        let resetsAt = try self.optionalDate(value, property: "resetsAt", path: "cost")
        let nextRegenAmount = try self.optionalFiniteNumber(value, property: "nextRegenAmount", path: "cost")
        let balance = try self.optionalFiniteNumber(value, property: "balance", path: "cost")
        return ProviderCostSnapshot(
            used: used,
            limit: limit,
            currencyCode: currency,
            period: period,
            resetsAt: resetsAt,
            nextRegenAmount: nextRegenAmount,
            balance: balance,
            updatedAt: now)
    }

    private static func costUsage(
        _ root: any ProviderPluginValue) throws -> CostUsageTokenSnapshot?
    {
        guard let value = root.property("costUsage"), !value.isUndefined, !value.isNull else { return nil }
        guard value.isObject, !value.isArray else {
            throw ProviderPluginError.invalidSnapshot("costUsage must be an object")
        }
        let currency = try self.requiredString(value, property: "currency", path: "costUsage")
        guard currency.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil else {
            throw ProviderPluginError.invalidSnapshot(
                "costUsage.currency must be a three-letter uppercase currency literal")
        }
        let historyDays = try self.requiredPositiveInteger(
            value,
            property: "historyDays",
            path: "costUsage")
        guard historyDays <= 366 else {
            throw ProviderPluginError.invalidSnapshot("costUsage.historyDays exceeds 366")
        }
        let historyLabel = try self.optionalString(value, property: "historyLabel", path: "costUsage")
        let windowEnd = try self.requiredString(value, property: "windowEnd", path: "costUsage")
        guard windowEnd.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil,
              let windowEndDate = CostUsageDateParser.parse("\(windowEnd)T12:00:00Z")
        else {
            throw ProviderPluginError.invalidSnapshot("costUsage.windowEnd must be a valid YYYY-MM-DD date")
        }
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let windowStartDate = utcCalendar.date(
            byAdding: .day,
            value: -(historyDays - 1),
            to: windowEndDate) ?? windowEndDate
        guard let entriesValue = value.property("entries"), entriesValue.isArray else {
            throw ProviderPluginError.invalidSnapshot("costUsage.entries must be an array")
        }
        let count = Int(entriesValue.property("length")?.int32Value() ?? 0)
        guard count <= 10000 else {
            throw ProviderPluginError.invalidSnapshot("costUsage.entries exceeds 10000 entries")
        }

        let parsedEntries = try self.costUsageEntries(
            entriesValue,
            count: count,
            windowStartDate: windowStartDate,
            windowEndDate: windowEndDate)
        let aggregation = try self.aggregateCostUsageEntries(parsedEntries)
        let meteredCost = aggregation.totalCost - aggregation.totalEstimatedCost
        let provenance: CostProvenance = if aggregation.totalEstimatedCost > 0 {
            meteredCost > 0 ? .mixed : .listPriceEstimate
        } else {
            .vendorMetered
        }
        return CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            sessionRequests: nil,
            last30DaysTokens: aggregation.totalTokens,
            last30DaysCostUSD: aggregation.totalCost,
            last30DaysRequests: aggregation.totalRequests,
            currencyCode: currency,
            historyDays: historyDays,
            historyCoverageIsEstablished: true,
            historyLabel: historyLabel,
            meteredCostUSD: aggregation.totalEstimatedCost > 0 && meteredCost > 0 ? meteredCost : nil,
            costProvenance: provenance,
            daily: aggregation.daily,
            updatedAt: windowEndDate)
    }

    private static func costUsageEntries(
        _ entriesValue: any ProviderPluginValue,
        count: Int,
        windowStartDate: Date,
        windowEndDate: Date) throws -> [CostUsageParsedEntry]
    {
        try (0..<count).map { index in
            guard let entry = entriesValue.element(at: index), entry.isObject, !entry.isArray else {
                throw ProviderPluginError.invalidSnapshot("costUsage.entries[\(index)] must be an object")
            }
            let path = "costUsage.entries[\(index)]"
            let date = try self.requiredString(entry, property: "date", path: path)
            guard date.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil,
                  let entryDate = CostUsageDateParser.parse("\(date)T12:00:00Z")
            else {
                throw ProviderPluginError.invalidSnapshot("\(path).date must be a valid YYYY-MM-DD date")
            }
            guard entryDate >= windowStartDate, entryDate <= windowEndDate else {
                throw ProviderPluginError.invalidSnapshot("\(path).date falls outside the declared history window")
            }
            let inputTokens = try self.requiredNonnegativeInteger(entry, property: "inputTokens", path: path)
            let outputTokens = try self.requiredNonnegativeInteger(entry, property: "outputTokens", path: path)
            let reasoningTokens = try self.optionalNonnegativeInteger(
                entry,
                property: "reasoningTokens",
                path: path)
            if let reasoningTokens, reasoningTokens > outputTokens {
                throw ProviderPluginError.invalidSnapshot("\(path).reasoningTokens must not exceed outputTokens")
            }
            let requests = try self.requiredNonnegativeInteger(entry, property: "requests", path: path)
            let cost = try self.requiredFiniteNumber(entry, property: "cost", path: path)
            guard cost >= 0 else {
                throw ProviderPluginError.invalidSnapshot("\(path).cost must be nonnegative")
            }
            let estimatedCost = try self.optionalFiniteNumber(
                entry,
                property: "estimatedCost",
                path: path) ?? 0
            guard estimatedCost >= 0, estimatedCost <= cost else {
                throw ProviderPluginError.invalidSnapshot(
                    "\(path).estimatedCost must be nonnegative and no greater than cost")
            }
            let rowTokens = inputTokens.addingReportingOverflow(outputTokens)
            guard !rowTokens.overflow else {
                throw ProviderPluginError.invalidSnapshot("\(path) token total overflowed")
            }
            return try CostUsageParsedEntry(
                date: date,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                reasoningTokens: reasoningTokens,
                requests: requests,
                cost: cost,
                estimatedCost: estimatedCost,
                model: self.optionalString(entry, property: "model", path: path))
        }
    }

    private static func aggregateCostUsageEntries(
        _ parsedEntries: [CostUsageParsedEntry]) throws -> CostUsageAggregation
    {
        var grouped: [String: CostUsageAccumulator] = [:]
        for entry in parsedEntries {
            let key = "\(entry.date)\u{1F}\(entry.model ?? "")"
            var accumulator = grouped[key] ?? CostUsageAccumulator()
            accumulator.inputTokens = try self.checkedSum(
                accumulator.inputTokens, entry.inputTokens, path: "costUsage input token total")
            accumulator.outputTokens = try self.checkedSum(
                accumulator.outputTokens, entry.outputTokens, path: "costUsage output token total")
            if let reasoningTokens = entry.reasoningTokens {
                accumulator.reasoningTokens = try self.checkedSum(
                    accumulator.reasoningTokens, reasoningTokens, path: "costUsage reasoning token total")
                accumulator.hasReasoningTokens = true
            }
            accumulator.requests = try self.checkedSum(
                accumulator.requests, entry.requests, path: "costUsage request total")
            accumulator.cost += entry.cost
            accumulator.estimatedCost += entry.estimatedCost
            if entry.estimatedCost > 0 {
                accumulator.estimatedRequests = try self.checkedSum(
                    accumulator.estimatedRequests, entry.requests, path: "costUsage estimated request total")
            }
            guard accumulator.cost.isFinite, accumulator.estimatedCost.isFinite else {
                throw ProviderPluginError.invalidSnapshot("costUsage cost total overflowed")
            }
            grouped[key] = accumulator
        }

        var dailyGrouped: [String: CostUsageAccumulator] = [:]
        var breakdownsByDate: [String: [CostUsageDailyReport.ModelBreakdown]] = [:]
        for key in grouped.keys.sorted() {
            let parts = key.split(separator: "\u{1F}", maxSplits: 1, omittingEmptySubsequences: false)
            let date = String(parts[0])
            let model = parts.count > 1 && !parts[1].isEmpty ? String(parts[1]) : nil
            let accumulator = grouped[key]!
            let totalTokens = try self.checkedSum(
                accumulator.inputTokens, accumulator.outputTokens, path: "costUsage token total")
            if let breakdown = model.map({
                CostUsageDailyReport.ModelBreakdown(
                    modelName: $0,
                    costUSD: accumulator.cost,
                    totalTokens: totalTokens,
                    requestCount: accumulator.requests,
                    inputTokens: accumulator.inputTokens,
                    outputTokens: accumulator.outputTokens,
                    reasoningTokens: accumulator.hasReasoningTokens ? accumulator.reasoningTokens : nil)
            }) {
                breakdownsByDate[date, default: []].append(breakdown)
            }
            var daily = dailyGrouped[date] ?? CostUsageAccumulator()
            daily.inputTokens = try self.checkedSum(
                daily.inputTokens, accumulator.inputTokens, path: "costUsage daily input token total")
            daily.outputTokens = try self.checkedSum(
                daily.outputTokens, accumulator.outputTokens, path: "costUsage daily output token total")
            daily.reasoningTokens = try self.checkedSum(
                daily.reasoningTokens, accumulator.reasoningTokens, path: "costUsage daily reasoning token total")
            daily.hasReasoningTokens = daily.hasReasoningTokens || accumulator.hasReasoningTokens
            daily.requests = try self.checkedSum(
                daily.requests, accumulator.requests, path: "costUsage daily request total")
            daily.estimatedRequests = try self.checkedSum(
                daily.estimatedRequests,
                accumulator.estimatedRequests,
                path: "costUsage daily estimated request total")
            daily.cost += accumulator.cost
            daily.estimatedCost += accumulator.estimatedCost
            guard daily.cost.isFinite, daily.estimatedCost.isFinite else {
                throw ProviderPluginError.invalidSnapshot("costUsage daily cost total overflowed")
            }
            dailyGrouped[date] = daily
        }

        let daily = try dailyGrouped.keys.sorted().map { date in
            let accumulator = dailyGrouped[date]!
            let totalTokens = try self.checkedSum(
                accumulator.inputTokens, accumulator.outputTokens, path: "costUsage token total")
            let breakdowns = breakdownsByDate[date]
            return CostUsageDailyReport.Entry(
                date: date,
                inputTokens: accumulator.inputTokens,
                outputTokens: accumulator.outputTokens,
                reasoningTokens: accumulator.hasReasoningTokens ? accumulator.reasoningTokens : nil,
                totalTokens: totalTokens,
                requestCount: accumulator.requests,
                costUSD: accumulator.cost,
                modelsUsed: breakdowns?.map(\.modelName),
                modelBreakdowns: breakdowns,
                estimatedRequestCount: accumulator.estimatedRequests > 0 ? accumulator.estimatedRequests : nil)
        }
        let totalTokens = try daily.compactMap(\.totalTokens).reduce(0) {
            try self.checkedSum($0, $1, path: "costUsage token total")
        }
        let totalRequests = try daily.compactMap(\.requestCount).reduce(0) {
            try self.checkedSum($0, $1, path: "costUsage request total")
        }
        let totalCost = daily.compactMap(\.costUSD).reduce(0, +)
        let totalEstimatedCost = parsedEntries.reduce(0) { $0 + $1.estimatedCost }
        guard totalCost.isFinite, totalEstimatedCost.isFinite else {
            throw ProviderPluginError.invalidSnapshot("costUsage cost total overflowed")
        }
        return CostUsageAggregation(
            daily: daily,
            totalTokens: totalTokens,
            totalRequests: totalRequests,
            totalCost: totalCost,
            totalEstimatedCost: totalEstimatedCost)
    }

    private static func checkedSum(_ lhs: Int, _ rhs: Int, path: String) throws -> Int {
        let sum = lhs.addingReportingOverflow(rhs)
        guard !sum.overflow, Double(sum.partialValue) <= self.maximumJavaScriptSafeInteger else {
            throw ProviderPluginError.invalidSnapshot("\(path) overflowed")
        }
        return sum.partialValue
    }

    private static func identity(
        _ root: any ProviderPluginValue,
        provider: ProviderInstanceID) throws -> ProviderIdentitySnapshot?
    {
        guard let value = root.property("identity"), !value.isUndefined, !value.isNull else { return nil }
        guard value.isObject, !value.isArray else {
            throw ProviderPluginError.invalidSnapshot("identity must be an object")
        }
        return try ProviderIdentitySnapshot(
            providerID: provider,
            accountEmail: self.optionalString(value, property: "email", path: "identity"),
            accountOrganization: self.optionalString(value, property: "organization", path: "identity"),
            loginMethod: self.optionalString(value, property: "loginMethod", path: "identity"),
            accountID: self.optionalString(value, property: "accountID", path: "identity"))
    }

    private static func requiredFiniteNumber(
        _ value: any ProviderPluginValue,
        property: String,
        path: String) throws -> Double
    {
        guard let result = try self.optionalFiniteNumber(value, property: property, path: path) else {
            throw ProviderPluginError.invalidSnapshot("\(path).\(property) is required")
        }
        return result
    }

    private static func optionalFiniteNumber(
        _ value: any ProviderPluginValue,
        property: String,
        path: String) throws -> Double?
    {
        guard let propertyValue = value.property(property),
              !propertyValue.isUndefined,
              !propertyValue.isNull
        else { return nil }
        guard propertyValue.isNumber else {
            throw ProviderPluginError.invalidSnapshot("\(path).\(property) must be a number")
        }
        let number = propertyValue.doubleValue()
        guard number.isFinite else {
            throw ProviderPluginError.invalidSnapshot("\(path).\(property) must be finite")
        }
        return number
    }

    private static func optionalPositiveInteger(
        _ value: any ProviderPluginValue,
        property: String,
        path: String) throws -> Int?
    {
        guard let number = try self.optionalFiniteNumber(value, property: property, path: path) else { return nil }
        guard number.rounded() == number, number > 0, number <= self.maximumJavaScriptSafeInteger else {
            throw ProviderPluginError.invalidSnapshot("\(path).\(property) must be a positive integer")
        }
        return Int(number)
    }

    private static func requiredPositiveInteger(
        _ value: any ProviderPluginValue,
        property: String,
        path: String) throws -> Int
    {
        guard let result = try self.optionalPositiveInteger(value, property: property, path: path) else {
            throw ProviderPluginError.invalidSnapshot("\(path).\(property) is required")
        }
        return result
    }

    private static func requiredNonnegativeInteger(
        _ value: any ProviderPluginValue,
        property: String,
        path: String) throws -> Int
    {
        guard let result = try self.optionalNonnegativeInteger(value, property: property, path: path) else {
            throw ProviderPluginError.invalidSnapshot("\(path).\(property) is required")
        }
        return result
    }

    private static func optionalNonnegativeInteger(
        _ value: any ProviderPluginValue,
        property: String,
        path: String) throws -> Int?
    {
        guard let number = try self.optionalFiniteNumber(value, property: property, path: path) else { return nil }
        guard number.rounded() == number, number >= 0, number <= self.maximumJavaScriptSafeInteger else {
            throw ProviderPluginError.invalidSnapshot("\(path).\(property) must be a nonnegative integer")
        }
        return Int(number)
    }

    private static func requiredString(
        _ value: any ProviderPluginValue,
        property: String,
        path: String) throws -> String
    {
        guard let string = try self.optionalString(value, property: property, path: path) else {
            throw ProviderPluginError.invalidSnapshot("\(path).\(property) is required")
        }
        return string
    }

    private static func optionalString(
        _ value: any ProviderPluginValue,
        property: String,
        path: String) throws -> String?
    {
        guard let propertyValue = value.property(property),
              !propertyValue.isUndefined,
              !propertyValue.isNull
        else { return nil }
        guard propertyValue.isString else {
            throw ProviderPluginError.invalidSnapshot("\(path).\(property) must be a string")
        }
        let string = propertyValue.stringValue().trimmingCharacters(in: .whitespacesAndNewlines)
        guard string.utf8.count <= self.maximumStringBytes else {
            throw ProviderPluginError.invalidSnapshot(
                "\(path).\(property) exceeds \(self.maximumStringBytes) UTF-8 bytes")
        }
        return string.isEmpty ? nil : string
    }

    private static func optionalDate(
        _ value: any ProviderPluginValue,
        property: String,
        path: String = "snapshot") throws -> Date?
    {
        guard let propertyValue = value.property(property),
              !propertyValue.isUndefined,
              !propertyValue.isNull
        else { return nil }
        if propertyValue.isDate, let date = propertyValue.dateValue() {
            return date
        }
        guard propertyValue.isString else {
            throw ProviderPluginError.invalidSnapshot("\(path).\(property) must be a Date or ISO-8601 string")
        }
        let text = propertyValue.stringValue()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        guard let date = fractional.date(from: text) ?? plain.date(from: text) else {
            throw ProviderPluginError.invalidSnapshot("\(path).\(property) is not a valid ISO-8601 date")
        }
        return date
    }
}
