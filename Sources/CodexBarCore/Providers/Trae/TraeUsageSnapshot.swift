import Foundation

public struct TraeEntitlementInfo: Sendable {
    public let name: String
    public let totalCredits: Double
    public let usedCredits: Double
    public let expiresAt: Date?
    public let productType: Int
    public let isUnlimited: Bool
    public let isActive: Bool

    public init(name: String, totalCredits: Double, usedCredits: Double, expiresAt: Date?, productType: Int, isUnlimited: Bool, isActive: Bool = true) {
        self.name = name
        self.totalCredits = totalCredits
        self.usedCredits = usedCredits
        self.expiresAt = expiresAt
        self.productType = productType
        self.isUnlimited = isUnlimited
        self.isActive = isActive
    }

    public var remainingCredits: Double {
        if isUnlimited { return -1 }
        return max(0, totalCredits - usedCredits)
    }

    public var usedPercent: Double {
        if isUnlimited || totalCredits <= 0 { return 0 }
        return min(100, (usedCredits / totalCredits) * 100)
    }

    public var remainingDescription: String {
        // Keep simple - just the credit count, no "resets" prefix
        if isUnlimited {
            return "Unlimited"
        }
        let remaining = remainingCredits
        if remaining == 0 {
            return "0 Left"
        }
        // Format with 0-2 decimal places based on value
        if remaining == floor(remaining) {
            return "\(Int(remaining)) Left"
        } else {
            return String(format: "%.2f Left", remaining)
        }
    }
}

public struct TraeFeatures: Sendable {
    public var hasSoloBuilder: Bool
    public var hasSoloCoder: Bool
    public var hasUnlimitedSlow: Bool
    public var hasUnlimitedAdvanced: Bool
    public var hasUnlimitedAutocomplete: Bool

    public init(hasSoloBuilder: Bool = false, hasSoloCoder: Bool = false, hasUnlimitedSlow: Bool = false, hasUnlimitedAdvanced: Bool = false, hasUnlimitedAutocomplete: Bool = false) {
        self.hasSoloBuilder = hasSoloBuilder
        self.hasSoloCoder = hasSoloCoder
        self.hasUnlimitedSlow = hasUnlimitedSlow
        self.hasUnlimitedAdvanced = hasUnlimitedAdvanced
        self.hasUnlimitedAutocomplete = hasUnlimitedAutocomplete
    }

    public var hasAnyFeatures: Bool {
        hasSoloBuilder || hasSoloCoder || hasUnlimitedSlow || hasUnlimitedAdvanced || hasUnlimitedAutocomplete
    }
}

public struct TraeUsageSnapshot: Sendable {
    public let entitlements: [TraeEntitlementInfo]
    public let features: TraeFeatures
    public let totalEntitlements: Int
    public let activeEntitlements: Int
    public let updatedAt: Date

    public init(entitlements: [TraeEntitlementInfo], features: TraeFeatures, totalEntitlements: Int, activeEntitlements: Int, updatedAt: Date) {
        self.entitlements = entitlements
        self.features = features
        self.totalEntitlements = totalEntitlements
        self.activeEntitlements = activeEntitlements
        self.updatedAt = updatedAt
    }

    // Legacy accessors for compatibility
    public var totalCredits: Double {
        entitlements.reduce(0) { $0 + ($1.isUnlimited ? 0 : $1.totalCredits) }
    }

    public var usedCredits: Double {
        entitlements.reduce(0) { $0 + $1.usedCredits }
    }

    public var planName: String {
        let proPlan = entitlements.first { $0.productType == 1 }
        return proPlan?.name ?? "Trae"
    }

    public var expiresAt: Date? {
        entitlements.compactMap { $0.expiresAt }.min()
    }
}

extension TraeUsageSnapshot {
    public func toUsageSnapshot(now: Date = Date()) -> UsageSnapshot {
        // Map up to 3 entitlements to primary/secondary/tertiary windows
        let primary = self.makeWindow(from: entitlements.indices.contains(0) ? entitlements[0] : nil, now: now)
        let secondary = self.makeWindow(from: entitlements.indices.contains(1) ? entitlements[1] : nil, now: now)
        let tertiary = self.makeWindow(from: entitlements.indices.contains(2) ? entitlements[2] : nil, now: now)

        // Build rich plan description with features
        var planDetails: [String] = []
        if features.hasSoloBuilder {
            planDetails.append("Solo Builder")
        }
        if features.hasSoloCoder {
            planDetails.append("Solo Coder")
        }
        if features.hasUnlimitedSlow {
            planDetails.append("Slow Requests")
        }
        if features.hasUnlimitedAdvanced {
            planDetails.append("Advanced Model")
        }
        if features.hasUnlimitedAutocomplete {
            planDetails.append("Autocomplete")
        }

        let planName = entitlements.first?.name ?? "Trae"
        let richPlanName = planDetails.isEmpty ? planName : "\(planName) (\(planDetails.joined(separator: ", ")))"

        let identity = ProviderIdentitySnapshot(
            providerID: .trae,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: richPlanName)

        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: tertiary,
            providerCost: nil,
            updatedAt: self.updatedAt,
            identity: identity)
    }

    private func makeWindow(from entitlement: TraeEntitlementInfo?, now: Date) -> RateWindow? {
        guard let entitlement else { return nil }

        let windowMinutes: Int? = {
            guard let expiry = entitlement.expiresAt else { return nil }
            let minutes = Int(expiry.timeIntervalSince(now) / 60)
            return minutes > 0 ? minutes : nil
        }()

        // Simple approach: just percentage and reset date
        // UsageFormatter.resetLine will show "Resets [date]" or countdown
        return RateWindow(
            usedPercent: entitlement.usedPercent,
            windowMinutes: windowMinutes,
            resetsAt: entitlement.expiresAt,
            resetDescription: nil)
    }
}
