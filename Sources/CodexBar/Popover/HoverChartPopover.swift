import CodexBarCore
import SwiftUI

// MARK: - HoverChartPopover

/// hover 驱动的二级图表 popover：进入延迟打开、离开宽限关闭（复刻 NSMenu 子菜单 hover 级联）。
/// 同时保留外部通过 isPresented binding 的点击立即打开。
///
/// 行为细节：
/// - 鼠标悬停触发区 ~0.18s 后自动打开（短延迟防扫过误触）。
/// - 鼠标离开触发区后 0.35s 宽限——期间进入 popover 内容则保持打开。
/// - 触发区与内容都不 hover 且宽限到期 → 关闭。
/// - 点击 → 立即打开（isPresented = true，binding 外部持有）。
/// - chart 为 nil 时 modifier 不挂任何东西，原样透传。
struct HoverChartPopover: ViewModifier {
    let chart: PopoverChartKind?
    let makeChartView: (PopoverChartKind, CGFloat) -> AnyView?
    /// 触发视图的点击仍直接置 true；hover 逻辑也通过此 binding 驱动开关。
    @Binding var isPresented: Bool

    @State private var rowHovered = false
    @State private var contentHovered = false
    @State private var openTask: Task<Void, Never>?
    @State private var closeTask: Task<Void, Never>?

    private static let openDelay: Duration = .milliseconds(180)
    private static let closeGrace: Duration = .milliseconds(350)

    func body(content: Content) -> some View {
        if let chart {
            content
                .onHover { hovering in
                    self.rowHovered = hovering
                    if hovering {
                        self.closeTask?.cancel()
                        self.scheduleOpen()
                    } else {
                        self.openTask?.cancel()
                        self.scheduleCloseIfIdle()
                    }
                }
                .popover(isPresented: self.$isPresented, arrowEdge: .trailing) {
                    Group {
                        if let view = self.makeChartView(chart, 360) {
                            view
                        } else {
                            Text("No data available")
                                .foregroundStyle(.secondary)
                                .padding()
                        }
                    }
                    .frame(minWidth: 320)
                    .onHover { hovering in
                        self.contentHovered = hovering
                        if hovering {
                            self.closeTask?.cancel()
                        } else {
                            self.scheduleCloseIfIdle()
                        }
                    }
                }
        } else {
            content
        }
    }

    // MARK: - 私有调度方法

    private func scheduleOpen() {
        guard !self.isPresented else { return }
        self.openTask?.cancel()
        self.openTask = Task { @MainActor in
            try? await Task.sleep(for: Self.openDelay)
            guard !Task.isCancelled, self.rowHovered else { return }
            self.isPresented = true
        }
    }

    private func scheduleCloseIfIdle() {
        self.closeTask?.cancel()
        self.closeTask = Task { @MainActor in
            try? await Task.sleep(for: Self.closeGrace)
            guard !Task.isCancelled else { return }
            if !self.rowHovered, !self.contentHovered {
                self.isPresented = false
            }
        }
    }
}
