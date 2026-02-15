import Foundation

public struct WindsurfCachedPlanInfo: Codable, Sendable, Equatable {
    public let planName: String?
    public let startTimestamp: Int?
    public let endTimestamp: Int?
    public let usage: WindsurfPlanUsage?
    public let hasBillingWritePermissions: Bool?

    public init(
        planName: String?,
        startTimestamp: Int?,
        endTimestamp: Int?,
        usage: WindsurfPlanUsage?,
        hasBillingWritePermissions: Bool?)
    {
        self.planName = planName
        self.startTimestamp = startTimestamp
        self.endTimestamp = endTimestamp
        self.usage = usage
        self.hasBillingWritePermissions = hasBillingWritePermissions
    }
}

public struct WindsurfPlanUsage: Codable, Sendable, Equatable {
    public let duration: Int?
    public let messages: Int?
    public let flowActions: Int?
    public let flexCredits: Int?
    public let usedMessages: Int?
    public let usedFlowActions: Int?
    public let usedFlexCredits: Int?
    public let remainingMessages: Int?
    public let remainingFlowActions: Int?
    public let remainingFlexCredits: Int?

    public init(
        duration: Int?,
        messages: Int?,
        flowActions: Int?,
        flexCredits: Int?,
        usedMessages: Int?,
        usedFlowActions: Int?,
        usedFlexCredits: Int?,
        remainingMessages: Int?,
        remainingFlowActions: Int?,
        remainingFlexCredits: Int?)
    {
        self.duration = duration
        self.messages = messages
        self.flowActions = flowActions
        self.flexCredits = flexCredits
        self.usedMessages = usedMessages
        self.usedFlowActions = usedFlowActions
        self.usedFlexCredits = usedFlexCredits
        self.remainingMessages = remainingMessages
        self.remainingFlowActions = remainingFlowActions
        self.remainingFlexCredits = remainingFlexCredits
    }
}
