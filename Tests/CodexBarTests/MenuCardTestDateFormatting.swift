import Foundation
@testable import CodexBar

func minimaxRenewDate(_ timestamp: TimeInterval) -> String {
    let formatter = DateFormatter()
    formatter.locale = codexBarLocalizedLocale()
    formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
    formatter.setLocalizedDateFormatFromTemplate("MMM d, yyyy")
    return formatter.string(from: Date(timeIntervalSince1970: timestamp))
}
