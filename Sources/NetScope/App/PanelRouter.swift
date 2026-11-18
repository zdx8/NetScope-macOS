import Combine
import SwiftUI

/// 面板的「当前页」「当前排序」与「流量统计档位」。
///
/// 菜单栏三段现在只对应**两个**详情（清理释放 / 系统功能），但点 CPU 段和点内存段
/// 想要的默认排序不同。把这份状态抽出来，控制器只负责改它，
/// 视图跟着切换，省掉「为每个入口各建一套 View」的重复。
@MainActor
final class PanelRouter: ObservableObject {
    enum Tab: Hashable {
        case cleanup
        case system
    }

    @Published var tab: Tab = .cleanup
    @Published var sort: ProcessMetric = .cpu

    /// 流量统计的四档定义在 `Core/TrafficRange.swift`（自检要离线断言它的映射）
    @Published var trafficRange: TrafficRange = .live

    /// 菜单栏槽位 → 该打开哪一页、用哪种排序
    func route(to slot: MenuBarSlot) {
        switch slot {
        case .cpu:
            tab = .cleanup
            sort = .cpu
        case .memory:
            tab = .cleanup
            sort = .memory
        case .network:
            tab = .system
        }
    }
}
