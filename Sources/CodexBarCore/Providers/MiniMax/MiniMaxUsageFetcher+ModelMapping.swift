import Foundation

extension MiniMaxUsageParser {
    static func mapModelNameToServiceType(modelName: String) -> String {
        let lower = modelName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower == "general" || lower == "video" {
            return lower
        }

        // Legacy text model names are separate from Token Plan's `general` bucket.
        if self.isTextGenerationModelName(modelName) {
            return "Text Generation"
        }

        // Text to Speech (语音合成): speech-hd, Speech 2.8, etc.
        if lower.contains("speech") {
            return "Text to Speech"
        }

        // Image to Video Fast (图生视频 Fast): Hailuo-2.3-Fast
        if lower.contains("hailuo"), lower.contains("fast") {
            return "Image to Video"
        }

        // Text to Video (文生视频): Hailuo-2.3 (non-Fast)
        if lower.contains("hailuo") {
            return "Text to Video"
        }

        // Image Generation (图像生成): image-01, image-02, etc.
        if lower.hasPrefix("image-") {
            return "Image Generation"
        }

        // Music Generation (音乐生成): music-2.5, etc.
        if lower.contains("music") {
            return "Music Generation"
        }

        return modelName
    }

    static func isTextGenerationModelName(_ modelName: String) -> Bool {
        let lower = modelName.lowercased()
        return lower == "general" || lower.contains("minimax-m") || lower.hasPrefix("m2.")
    }

    static func shouldRenderWeeklyWindow(for modelName: String) -> Bool {
        self.isTextGenerationModelName(modelName)
    }

    static func formatMiniMaxDateTimeRange(startTime: Date?, endTime: Date?) -> String? {
        guard let startTime, let endTime else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "MM/dd HH:mm"
        let start = formatter.string(from: startTime)
        let end = formatter.string(from: endTime)
        return "\(start) - \(end)(UTC+8)"
    }
}
