import Foundation

public struct AntigravityCreditPool: Codable, Sendable, Equatable {
    public let available: Int?
    public let used: Int?
    public let userUsed: Int?
    public let monthly: Int?

    public init(
        available: Int? = nil,
        used: Int? = nil,
        userUsed: Int? = nil,
        monthly: Int? = nil)
    {
        self.available = available
        self.used = used
        self.userUsed = userUsed
        self.monthly = monthly
    }

    var isEmpty: Bool {
        self.available == nil && self.used == nil && self.userUsed == nil && self.monthly == nil
    }
}

public struct AntigravityTopUpStatus: Codable, Sendable, Equatable {
    public let enabled: Bool?
    public let criteriaMet: Bool?
    public let monthlyAmount: Int?
    public let spent: Int?
    public let increment: Int?
    public let transactionStatus: String?

    public init(
        enabled: Bool? = nil,
        criteriaMet: Bool? = nil,
        monthlyAmount: Int? = nil,
        spent: Int? = nil,
        increment: Int? = nil,
        transactionStatus: String? = nil)
    {
        self.enabled = enabled
        self.criteriaMet = criteriaMet
        self.monthlyAmount = monthlyAmount
        self.spent = spent
        self.increment = increment
        self.transactionStatus = transactionStatus
    }

    var isEmpty: Bool {
        self.enabled == nil && self.criteriaMet == nil && self.monthlyAmount == nil &&
            self.spent == nil && self.increment == nil && self.transactionStatus == nil
    }
}

public struct AntigravityTierCredit: Codable, Sendable, Equatable {
    public let creditType: String?
    public let creditAmount: Int?
    public let minimumCreditAmountForUsage: Int?

    public init(
        creditType: String? = nil,
        creditAmount: Int? = nil,
        minimumCreditAmountForUsage: Int? = nil)
    {
        self.creditType = creditType
        self.creditAmount = creditAmount
        self.minimumCreditAmountForUsage = minimumCreditAmountForUsage
    }
}

public struct AntigravityCreditsSnapshot: Codable, Sendable, Equatable {
    public let prompt: AntigravityCreditPool?
    public let flow: AntigravityCreditPool?
    public let flex: AntigravityCreditPool?
    public let monthlyFlexPurchaseAmount: Int?
    public let canBuyMoreCredits: Bool?
    public let topUpStatus: AntigravityTopUpStatus?
    public let planStart: Date?
    public let planEnd: Date?
    public let availableCredits: [AntigravityTierCredit]?

    public init(
        prompt: AntigravityCreditPool? = nil,
        flow: AntigravityCreditPool? = nil,
        flex: AntigravityCreditPool? = nil,
        monthlyFlexPurchaseAmount: Int? = nil,
        canBuyMoreCredits: Bool? = nil,
        topUpStatus: AntigravityTopUpStatus? = nil,
        planStart: Date? = nil,
        planEnd: Date? = nil,
        availableCredits: [AntigravityTierCredit]? = nil)
    {
        self.prompt = prompt
        self.flow = flow
        self.flex = flex
        self.monthlyFlexPurchaseAmount = monthlyFlexPurchaseAmount
        self.canBuyMoreCredits = canBuyMoreCredits
        self.topUpStatus = topUpStatus
        self.planStart = planStart
        self.planEnd = planEnd
        self.availableCredits = availableCredits
    }

    var isEmpty: Bool {
        self.prompt == nil && self.flow == nil && self.flex == nil &&
            self.monthlyFlexPurchaseAmount == nil && self.canBuyMoreCredits == nil &&
            self.topUpStatus == nil && self.planStart == nil && self.planEnd == nil &&
            (self.availableCredits?.isEmpty ?? true)
    }

    func merging(_ other: AntigravityCreditsSnapshot?) -> AntigravityCreditsSnapshot {
        guard let other else { return self }
        let mergedAvailableCredits = (self.availableCredits?.isEmpty == false)
            ? self.availableCredits
            : other.availableCredits
        return AntigravityCreditsSnapshot(
            prompt: self.prompt ?? other.prompt,
            flow: self.flow ?? other.flow,
            flex: self.flex ?? other.flex,
            monthlyFlexPurchaseAmount: self.monthlyFlexPurchaseAmount ?? other.monthlyFlexPurchaseAmount,
            canBuyMoreCredits: self.canBuyMoreCredits ?? other.canBuyMoreCredits,
            topUpStatus: self.topUpStatus ?? other.topUpStatus,
            planStart: self.planStart ?? other.planStart,
            planEnd: self.planEnd ?? other.planEnd,
            availableCredits: mergedAvailableCredits)
    }
}

public struct AntigravityModelAvailability: Codable, Sendable, Equatable {
    public let state: String
    public let explanation: String?

    public init(state: String, explanation: String? = nil) {
        self.state = state
        self.explanation = explanation
    }
}

public struct AntigravityAccountMetadata: Codable, Sendable, Equatable {
    public let g1Tier: String?
    public let teamsTier: String?
    public let isPro: Bool?
    public let gcpManaged: Bool?
    public let teamId: String?
    public let teamStatus: String?
    public let manageSubscriptionURI: String?
    public let upgradeSubscriptionURI: String?

    public init(
        g1Tier: String? = nil,
        teamsTier: String? = nil,
        isPro: Bool? = nil,
        gcpManaged: Bool? = nil,
        teamId: String? = nil,
        teamStatus: String? = nil,
        manageSubscriptionURI: String? = nil,
        upgradeSubscriptionURI: String? = nil)
    {
        self.g1Tier = g1Tier
        self.teamsTier = teamsTier
        self.isPro = isPro
        self.gcpManaged = gcpManaged
        self.teamId = teamId
        self.teamStatus = teamStatus
        self.manageSubscriptionURI = manageSubscriptionURI
        self.upgradeSubscriptionURI = upgradeSubscriptionURI
    }

    var isEmpty: Bool {
        self.g1Tier == nil && self.teamsTier == nil && self.isPro == nil &&
            self.gcpManaged == nil && self.teamId == nil && self.teamStatus == nil &&
            self.manageSubscriptionURI == nil && self.upgradeSubscriptionURI == nil
    }

    func merging(_ other: AntigravityAccountMetadata?) -> AntigravityAccountMetadata {
        guard let other else { return self }
        return AntigravityAccountMetadata(
            g1Tier: self.g1Tier ?? other.g1Tier,
            teamsTier: self.teamsTier ?? other.teamsTier,
            isPro: self.isPro ?? other.isPro,
            gcpManaged: self.gcpManaged ?? other.gcpManaged,
            teamId: self.teamId ?? other.teamId,
            teamStatus: self.teamStatus ?? other.teamStatus,
            manageSubscriptionURI: self.manageSubscriptionURI ?? other.manageSubscriptionURI,
            upgradeSubscriptionURI: self.upgradeSubscriptionURI ?? other.upgradeSubscriptionURI)
    }
}
