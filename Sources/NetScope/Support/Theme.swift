import AppKit
import SwiftUI

/// NetScope 视觉语义色系统。
///
/// 浅色模式保持清透微暖白/浅灰层级；深色模式采用纯黑底（`#000000`）搭配深炭灰卡片（`#141416`）
/// 与极细高光描边，避免传统深灰界面在菜单栏弹窗中发灰发闷。
enum Theme {
    // MARK: - 表面与背景

    /// 面板底：浅色 #F5F5F7 / 深色纯黑 #000000
    static let background = dynamic(light: 0xF5F5F7, dark: 0x000000)
    /// 卡片底：浅色 #FFFFFF / 深色 #141416
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x141416)
    /// 次级表面（分段槽、进度条槽、表头底）：浅色 #EBEBF0 / 深色 #1C1C1F
    static let surfaceMuted = dynamic(light: 0xEBEBF0, dark: 0x1C1C1F)
    /// 抬升/选中表面：浅色 #FFFFFF / 深色 #26262A
    static let surfaceElevated = dynamic(light: 0xFFFFFF, dark: 0x26262A)

    // MARK: - 文字层级

    static let textPrimary = dynamic(light: 0x111113, dark: 0xFFFFFF)
    static let textSecondary = dynamic(light: 0x48484A, dark: 0xA1A1A6)
    static let textTertiary = dynamic(light: 0x6E6E73, dark: 0x8E8E93)

    // MARK: - 描边与交互叠加

    /// 1px 描边：浅色黑 7% / 深色白 9%
    static let border = dynamicAlpha(light: 0x000000, lightAlpha: 0.07,
                                     dark: 0xFFFFFF, darkAlpha: 0.09)
    /// 强描边：分隔线与选中胶囊描边
    static let borderStrong = dynamic(light: 0xD1D1D6, dark: 0x3A3A3C)
    /// 强调色：主按钮底、选中态
    static let accent = dynamic(light: 0x1C1C1E, dark: 0xF5F5F7)
    /// 强调色上的文字
    static let onAccent = dynamic(light: 0xFFFFFF, dark: 0x000000)
    /// 悬停叠加
    static let hover = dynamicAlpha(light: 0x000000, lightAlpha: 0.045,
                                    dark: 0xFFFFFF, darkAlpha: 0.07)
    /// 卡片投影：浅色轻柔投影，深色纯黑底不铺阴影（靠高光描边分层）
    static let cardShadow = dynamicAlpha(light: 0x000000, lightAlpha: 0.05,
                                         dark: 0x000000, darkAlpha: 0.0)

    // MARK: - 数据与状态语义色

    /// 下行：蓝
    static let down = dynamic(light: 0x0A63E6, dark: 0x4DA3FF)
    /// 上行：琥珀
    static let up = dynamic(light: 0xB25A00, dark: 0xFFA340)
    /// CPU 曲线：青绿
    static let cpu = dynamic(light: 0x0F766E, dark: 0x4FD1C5)
    /// 内存曲线：紫罗兰
    static let memory = dynamic(light: 0x6D28D9, dark: 0xA78BFA)
    /// 正常状态点
    static let healthy = dynamic(light: 0x16A34A, dark: 0x32D74B)
    /// 暂停
    static let idle = dynamic(light: 0x8E8E93, dark: 0x8E8E93)
    /// 异常
    static let fault = dynamic(light: 0xC0262C, dark: 0xFF453A)

    static func accent(for status: MonitorEngine.Status) -> Color {
        switch status {
        case .running: return healthy
        case .starting: return up
        case .paused: return idle
        case .failed: return fault
        }
    }

    // MARK: - 动态色构造

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(hex: dark)
                : NSColor(hex: light)
        })
    }

    private static func dynamicAlpha(light: UInt32, lightAlpha: CGFloat,
                                     dark: UInt32, darkAlpha: CGFloat) -> Color {
        Color(NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
                .withAlphaComponent(isDark ? darkAlpha : lightAlpha)
        })
    }
}

extension NSColor {
    /// `0xRRGGBB` → 不透明 sRGB 颜色。
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}
