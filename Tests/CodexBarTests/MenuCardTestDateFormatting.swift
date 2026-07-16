import Foundation

func minimaxRenewDate(_ timestamp: TimeInterval) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
    formatter.setLocalizedDateFormatFromTemplate("MMM d, yyyy")
    return formatter.string(from: Date(timeIntervalSince1970: timestamp))
}
