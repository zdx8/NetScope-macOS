import Foundation

/// 进程列表的排序口径。放在 Core 层而不是视图里：
/// 自检只编译纯逻辑层，需要能断言排序文案，不能把 SwiftUI 拖进来。
enum ProcessMetric: Hashable {
    case cpu
    case memory

    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "内存"
        }
    }

    /// 排序按钮上的完整文案（中文标签不加空格，拉丁缩写两侧留空格）
    var sortTitle: String {
        switch self {
        case .cpu: return "按 CPU"
        case .memory: return "按内存"
        }
    }
}
