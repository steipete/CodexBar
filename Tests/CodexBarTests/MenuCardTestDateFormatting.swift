import Foundation

func minimaxRenewDate(_ timestamp: TimeInterval) -> String {
    let formatter = DateFormatter()
    formatter.locale = .current
    formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
    formatter.setLocalizedDateFormatFromTemplate("MMM d, yyyy")
    return formatter.string(from: Date(timeIntervalSince1970: timestamp))
}
