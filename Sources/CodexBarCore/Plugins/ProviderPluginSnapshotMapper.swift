import Foundation

enum ProviderPluginSnapshotMapper {
    private static let maximumStringBytes = 256

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
        let openRouterActivityUsage = provider == .openrouter
            ? self.openRouterActivityUsage(value, now: now)
            : nil
        let details = try self.details(value)
        let identity = try self.identity(value, provider: provider)
        let subscriptionRenewsAt = try self.optionalDate(value, property: "subscriptionRenewsAt")
        let subscriptionExpiresAt = try self.optionalDate(value, property: "subscriptionExpiresAt")
        let dataConfidence = try self.dataConfidence(value)

        guard primary != nil || secondary != nil || tertiary != nil || !(extraRateWindows?.isEmpty ?? true)
            || providerCost != nil
            || !details.isEmpty
        else {
            throw ProviderPluginError.invalidSnapshot("snapshot must contain at least one rate window, cost, or detail")
        }

        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: tertiary,
            extraRateWindows: extraRateWindows,
            providerCost: providerCost,
            details: details,
            openRouterActivityUsage: openRouterActivityUsage,
            subscriptionExpiresAt: subscriptionExpiresAt,
            subscriptionRenewsAt: subscriptionRenewsAt,
            updatedAt: now,
            identity: identity,
            dataConfidence: dataConfidence)
    }

    /// Activity is an optional management-key enrichment. Malformed or unsupported
    /// activity must not invalidate an otherwise healthy provider snapshot.
    private static func openRouterActivityUsage(
        _ root: any ProviderPluginValue,
        now: Date) -> OpenRouterActivityUsageSnapshot?
    {
        guard let value = root.property("openRouterActivityUsage"),
              value.isObject,
              !value.isArray,
              !value.isNull,
              let rows = value.property("data"),
              rows.isArray,
              let rawCount = rows.property("length")?.int32Value(),
              rawCount >= 0,
              rawCount <= 10_000
        else { return nil }

        do {
            let items: [[String: Any]] = try (0..<Int(rawCount)).map { index in
                guard let row = rows.element(at: index), row.isObject, !row.isArray else {
                    throw ProviderPluginError.invalidSnapshot("openRouterActivityUsage.data must contain objects")
                }
                let path = "openRouterActivityUsage.data[\(index)]"
                return [
                    "date": try self.requiredString(row, property: "date", path: path),
                    "model": try self.requiredString(row, property: "model", path: path),
                    "prompt_tokens": try self.requiredNonnegativeInteger(
                        row,
                        property: "prompt_tokens",
                        path: path),
                    "completion_tokens": try self.requiredNonnegativeInteger(
                        row,
                        property: "completion_tokens",
                        path: path),
                    "reasoning_tokens": try self.requiredNonnegativeInteger(
                        row,
                        property: "reasoning_tokens",
                        path: path),
                    "requests": try self.requiredNonnegativeInteger(row, property: "requests", path: path),
                    "usage": try self.requiredNonnegativeNumber(row, property: "usage", path: path),
                ]
            }
            let data = try JSONSerialization.data(withJSONObject: ["data": items])
            return try OpenRouterActivityUsageSnapshot(data: data, now: now)
        } catch {
            return nil
        }
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
        guard number.rounded() == number, number > 0, number <= Double(Int.max) else {
            throw ProviderPluginError.invalidSnapshot("\(path).\(property) must be a positive integer")
        }
        return Int(number)
    }

    private static func requiredNonnegativeInteger(
        _ value: any ProviderPluginValue,
        property: String,
        path: String) throws -> Int
    {
        let number = try self.requiredFiniteNumber(value, property: property, path: path)
        guard number.rounded() == number, number >= 0, number <= Double(Int.max) else {
            throw ProviderPluginError.invalidSnapshot("\(path).\(property) must be a nonnegative integer")
        }
        return Int(number)
    }

    private static func requiredNonnegativeNumber(
        _ value: any ProviderPluginValue,
        property: String,
        path: String) throws -> Double
    {
        let number = try self.requiredFiniteNumber(value, property: property, path: path)
        guard number >= 0 else {
            throw ProviderPluginError.invalidSnapshot("\(path).\(property) must be nonnegative")
        }
        return number
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
