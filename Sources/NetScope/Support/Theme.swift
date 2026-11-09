import AppKit
import SwiftUI

/// 集中管理配色。只在这里写十六进制/分量值，别处一律引用语义名，
/// 否则改配色时必然漏改某处，而且"图标是这个色、界面是那个色"这类问题不会报错。
///
/// 2026-11-09 可读性重做：用户反馈面板看不清。原因有三——
/// 1. `.secondary`/`.tertiary` 在浅色毛玻璃上只有约 2.8:1 / 1.6:1 对比度（WCAG AA 要求 4.5:1）；
/// 2. 原主题色偏亮：#F1921A 琥珀白底对比仅约 2.2:1，#2D80F1 蓝约 3.4:1；
/// 3. 0 值速率在 `.secondary` 之上还叠了 0.6 透明度，浅上加浅。
/// 方案：所有参与文字可读性的颜色改为**动态色**——浅色模式取深值保对比，深色模式取亮值保亮度。
/// 各浅色值的白底对比度（相对亮度按 sRGB 线性化计算）：textSecondary 约 7.1:1、
/// textTertiary 约 3.4:1、down 约 5.3:1、up 约 4.8:1。
enum Theme {
    /// 下行：偏冷的蓝。浅色模式用深蓝，深色模式用亮蓝
    static let down = dynamicColor(
        light: NSColor(red: 0.039, green: 0.388, blue: 0.902, alpha: 1),   // #0A63E6
        dark:  NSColor(red: 0.302, green: 0.604, blue: 1.000, alpha: 1)   // #4D9AFF
    )
    /// 上行：琥珀色。浅色模式必须加深成焦糖色，原亮琥珀在白底上完全看不清
    static let up = dynamicColor(
        light: NSColor(red: 0.698, green: 0.353, blue: 0.000, alpha: 1),   // #B25A00
        dark:  NSColor(red: 1.000, green: 0.635, blue: 0.243, alpha: 1)     // #FFA23E
    )
    /// 正常状态点（浅色模式加深一档，毛玻璃上 7pt 小点才看得见）
    static let healthy = dynamicColor(
        light: NSColor(red: 0.086, green: 0.639, blue: 0.290, alpha: 1),    // #16A34A
        dark:  NSColor(red: 0.204, green: 0.780, blue: 0.427, alpha: 1)     // #34C76D
    )
    /// 暂停
    static let idle = Color.secondary
    /// 异常（白底约 3.9:1，仅用于状态点与错误图标，够用）
    static let fault = Color(red: 0.906, green: 0.298, blue: 0.235)        // #E74C3C

    /// 次要文字（替代原 `.secondary` 的文字位）：白底约 7.1:1，所有 9–11pt 说明文字统一用这个
    static let textSecondary = dynamicColor(
        light: NSColor(red: 0.341, green: 0.341, blue: 0.361, alpha: 1),   // #57575C
        dark:  NSColor(red: 0.690, green: 0.690, blue: 0.710, alpha: 1)     // #B0B0B5
    )
    /// 辅助文字（替代原 `.tertiary` 的文字位）：白底约 3.4:1，只给 8–9.5pt 的真正辅助小字
    static let textTertiary = dynamicColor(
        light: NSColor(red: 0.541, green: 0.541, blue: 0.565, alpha: 1),   // #8A8A90
        dark:  NSColor(red: 0.522, green: 0.522, blue: 0.549, alpha: 1)     // #85858C
    )

    static func accent(for status: MonitorEngine.Status) -> Color {
        switch status {
        case .running: return healthy
        case .starting: return up
        case .paused: return idle
        case .failed: return fault
        }
    }

    /// 用 NSColor 动态提供者做浅/深双值颜色。SwiftUI 的 `Color(NSColor)` 会保留动态性，
    /// 面板在系统切换外观时无需重启即可换色。
    private static func dynamicColor(light: NSColor, dark: NSColor) -> Color {
        Color(NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}
