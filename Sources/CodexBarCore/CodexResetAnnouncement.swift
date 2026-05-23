import Foundation

/// A parsed announcement that a Codex usage-limit reset has been observed from an external source.
///
/// This is a pure data container produced by ``CodexResetAnnouncementParser``.
/// It intentionally carries no ``rawText`` to avoid persisting arbitrary user content
/// (e.g., DMs or mentions) that may appear alongside an announcement.
///
/// - note: This type does not perform network access, mutate quota state, or send notifications.
///   It is the foundation for phase-1 of #1103: representation and safe parsing only.
public enum CodexResetAnnouncementStatus: String, Codable, Sendable {
    case upcoming
    case completed
    case ambiguous
}

public struct CodexResetAnnouncement: Codable, Equatable, Sendable {
    public let sourceName: String
    public let sourceURL: String?
    public let observedAt: Date
    public let announcedResetAt: Date?
    public let status: CodexResetAnnouncementStatus
    public let confidence: Double?

    public init(
        sourceName: String,
        sourceURL: String? = nil,
        observedAt: Date = Date(),
        announcedResetAt: Date? = nil,
        status: CodexResetAnnouncementStatus,
        confidence: Double? = nil)
    {
        self.sourceName = sourceName
        self.sourceURL = sourceURL
        self.observedAt = observedAt
        self.announcedResetAt = announcedResetAt
        self.status = status
        self.confidence = confidence
    }
}
