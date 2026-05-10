//
//  MiniMaxServiceUsage.swift
//  CodexBarCore
//
//  Created by Sisyphus on 2026-03-25.
//

import Foundation

/// Represents the usage information for a specific MiniMax service.
///
/// This struct encapsulates all the relevant details about how much of a particular
/// MiniMax service has been used within its quota window, including reset timing
/// and localized display strings.
public struct MiniMaxServiceUsage: Sendable {
    /// The service identifier (e.g., "text-generation", "text-to-speech", "image")
    public let serviceType: String

    /// The type of time window for the quota (e.g., "5 hours" or "Today")
    /// This should be a localized string.
    public let windowType: String

    /// The specific time range for the current quota window.
    /// For hourly quotas: "10:00-15:00(UTC+8)"
    /// For daily quotas: full date range string
    public let timeRange: String

    /// The amount of quota that has been used.
    public let usage: Int

    /// The total quota limit for this service in the current window
    public let limit: Int

    /// The percentage of quota used (0-100)
    public let percent: Double

    /// The timestamp when the quota will reset, if available
    public let resetsAt: Date?

    /// A localized description of when the quota resets (e.g., "Resets in 2 hours 30 minutes")
    public let resetDescription: String

    /// The remaining quota available (limit - usage)
    public var remaining: Int {
        max(0, self.limit - self.usage)
    }

    /// The display name for this service
    public var displayName: String {
        switch self.serviceType {
        case "text-generation":
            "Text Generation"
        case "text-to-speech":
            "Text to Speech"
        case "image":
            "Image"
        default:
            self.serviceType
        }
    }

    /// Creates a new MiniMaxServiceUsage instance.
    ///
    /// - Parameters:
    ///   - serviceType: The service identifier
    ///   - windowType: The type of time window (localized)
    ///   - timeRange: The specific time range string
    ///   - usage: The amount of quota used
    ///   - limit: The total quota limit
    ///   - percent: The percentage used (0-100)
    ///   - resetsAt: Optional reset timestamp
    ///   - resetDescription: Localized reset description
    public init(
        serviceType: String,
        windowType: String,
        timeRange: String,
        usage: Int,
        limit: Int,
        percent: Double,
        resetsAt: Date?,
        resetDescription: String)
    {
        self.serviceType = serviceType
        self.windowType = windowType
        self.timeRange = timeRange
        self.usage = usage
        self.limit = limit
        self.percent = percent
        self.resetsAt = resetsAt
        self.resetDescription = resetDescription
    }
}

extension MiniMaxServiceUsage {
    public static func parseWindowType(_ windowType: String) -> (windowType: String, windowMinutes: Int?) {
        switch windowType.lowercased() {
        case "5 hours", "5 小时":
            return ("5 hours", 300)
        case "today", "今日":
            return ("Today", 1440)
        default:
            // Try to extract hours from string like "X hours"
            if let hours = Int(windowType.components(separatedBy: .whitespaces).first ?? "") {
                return (windowType, hours * 60)
            }
            return (windowType, nil)
        }
    }

    public static func parseTimeRange(_ timeRange: String, now: Date) -> Date? {
        let calendar = Calendar.current

        // Handle "10:00-15:00(UTC+8)" format
        if timeRange.contains("-"), timeRange.contains("("), timeRange.contains(")") {
            // Extract the time part before the timezone
            let components = timeRange.split(separator: "(")
            guard components.count >= 1 else { return nil }
            let timePart = String(components[0]).trimmingCharacters(in: .whitespaces)

            // Split by "-" to get start and end times
            let timeComponents = timePart.split(separator: "-")
            guard timeComponents.count == 2 else { return nil }

            let endTimeStr = String(timeComponents[1]).trimmingCharacters(in: .whitespaces)

            // Parse end time (HH:mm format)
            let timeFormatter = DateFormatter()
            timeFormatter.dateFormat = "HH:mm"
            timeFormatter.timeZone = TimeZone.current

            guard let endTime = timeFormatter.date(from: endTimeStr) else { return nil }

            // Get today's date components
            let nowComponents = calendar.dateComponents([.year, .month, .day], from: now)
            let endTimeComponents = calendar.dateComponents([.hour, .minute], from: endTime)

            // Combine today's date with end time
            var combinedComponents = DateComponents()
            combinedComponents.year = nowComponents.year
            combinedComponents.month = nowComponents.month
            combinedComponents.day = nowComponents.day
            combinedComponents.hour = endTimeComponents.hour
            combinedComponents.minute = endTimeComponents.minute

            guard let resultDate = calendar.date(from: combinedComponents) else { return nil }

            // If the result date is in the past (before now), add one day
            if resultDate < now {
                return calendar.date(byAdding: .day, value: 1, to: resultDate)
            }

            return resultDate
        }

        // Handle "2026/03/25 00:00 - 2026/03/26 00:00" format
        if timeRange.contains(" - ") {
            let dateComponents = timeRange.split(separator: " - ")
            guard dateComponents.count == 2 else { return nil }

            let endDateStr = String(dateComponents[1]).trimmingCharacters(in: .whitespaces)

            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy/MM/dd HH:mm"
            dateFormatter.timeZone = TimeZone.current

            return dateFormatter.date(from: endDateStr)
        }

        return nil
    }

    public static func generateResetDescription(resetsAt: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.hour, .minute], from: now, to: resetsAt)

        guard let hours = components.hour, let minutes = components.minute else {
            return "Resets soon"
        }

        if hours > 0, minutes > 0 {
            return "Resets in \(hours) hours \(minutes) minutes"
        } else if hours > 0 {
            return "Resets in \(hours) hour\(hours > 1 ? "s" : "")"
        } else if minutes > 0 {
            return "Resets in \(minutes) minute\(minutes > 1 ? "s" : "")"
        } else {
            return "Resets now"
        }
    }
}
