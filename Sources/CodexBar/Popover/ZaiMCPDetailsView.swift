import CodexBarCore
import SwiftUI

/// Zai MCP 用量明细视图：等价于 NSMenu makeZaiUsageDetailsSubmenu 的只读列表渲染。
/// 在 popoverChartView(.zaiDetails) 中使用，作为二级 popover 内容。
struct ZaiMCPDetailsView: View {
    let timeLimit: ZaiLimitEntry
    let resetTimeDisplayStyle: ResetTimeDisplayStyle
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题行
            Text(L("MCP details"))
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 4)

            // window 行
            if let window = self.timeLimit.windowLabel {
                Text(String(format: L("mcp_window"), window))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 2)
            }

            // 重置时间行
            if let resetTime = self.timeLimit.nextResetTime {
                let reset = self.resetTimeDisplayStyle == .absolute
                    ? UsageFormatter.resetDescription(from: resetTime)
                    : UsageFormatter.resetCountdownDescription(from: resetTime)
                Text(String(format: L("mcp_resets"), reset))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 2)
            }

            Divider()
                .padding(.vertical, 4)

            // 模型用量明细
            let sortedDetails = self.timeLimit.usageDetails.sorted {
                $0.modelCode.localizedCaseInsensitiveCompare($1.modelCode) == .orderedAscending
            }
            ForEach(sortedDetails, id: \.modelCode) { detail in
                let usage = UsageFormatter.tokenCountString(detail.usage)
                Text(String(format: L("mcp_model_usage"), detail.modelCode, usage))
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 2)
            }

            Spacer(minLength: 8)
        }
        .frame(width: self.width, alignment: .leading)
    }
}
