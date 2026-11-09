import SwiftUI

/// 集中管理配色。只在这里写十六进制/分量值，别处一律引用语义名，
/// 否则改配色时必然漏改某处，而且"图标是这个色、界面是那个色"这类问题不会报错。
enum Theme {
    /// 下行：偏冷的蓝，与系统「网络」类图标一致
    static let down = Color(red: 0.176, green: 0.502, blue: 0.945)   // #2D80F1
    /// 上行：琥珀色，与下行形成稳定对比
    static let up = Color(red: 0.945, green: 0.573, blue: 0.098)     // #F1921A
    /// 正常状态点
    static let healthy = Color(red: 0.204, green: 0.780, blue: 0.427) // #34C76D
    /// 暂停
    static let idle = Color.secondary
    /// 异常
    static let fault = Color(red: 0.906, green: 0.298, blue: 0.235)   // #E74C3C

    static func accent(for status: MonitorEngine.Status) -> Color {
        switch status {
        case .running: return healthy
        case .starting: return up
        case .paused: return idle
        case .failed: return fault
        }
    }
}
