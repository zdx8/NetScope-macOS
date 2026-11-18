import Foundation

/// 流量统计的四档：实时速率、过去 24 小时（5 分钟均值）、
/// 过去 7 天（30 分钟均值）、过去 30 天（2 小时均值）。
/// 图表与下方的应用列表共用这一档位。
///
/// 独立成一个无依赖的枚举：`PanelRouter` 持有当前值，自检能离线断言档位到
/// 持久化粒度的映射（PanelRouter 本身是 @MainActor，编译进自检要拖一串 AppKit 依赖）。
enum TrafficRange: String, CaseIterable, Hashable {
    case live, day, week, month

    var title: String {
        switch self {
        case .live: return "实时"
        case .day: return "日"
        case .week: return "周"
        case .month: return "月"
        }
    }

    /// 历史档对应的持久化粒度；实时档不查库
    var granularity: HistoryStore.Granularity? {
        switch self {
        case .live: return nil
        case .day: return .fiveMinutes
        case .week: return .thirtyMinutes
        case .month: return .twoHours
        }
    }

    /// 范围文案（汇总行右端）
    var rangeLabel: String {
        switch self {
        case .live: return "近 60 秒"
        case .day: return "过去 24 小时"
        case .week: return "过去 7 天"
        case .month: return "过去 30 天"
        }
    }
}
