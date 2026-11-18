import AppKit
import SwiftUI

/// Astryx（meta/astryx，`neutral` 主题）令牌在 macOS 端的映射。
///
/// 为什么是这套值：Astryx 的主题就是一组 CSS 自定义属性，`neutral` 的
/// 语义色板全部用 `light-dark()` 成对声明。这里逐条抄过来，取值与
/// `@astryxdesign/theme-neutral/theme.css` 一致，改配色时能两边对照：
///
/// | 语义 | 浅色 | 深色 | Astryx 令牌 |
/// |---|---|---|---|
/// | 面板底 | `#F1F1F1` | `#1B1B1B` | `--color-background-body` |
/// | 卡片 | `#FFFFFF` | `#262626` | `--color-background-surface` |
/// | 主文字 | `#000000` | `#FFFFFF` | `--color-text-primary` |
/// | 次文字 | `#474747` | `#9E9E9E` | `--color-text-secondary` |
/// | 描边 | 黑 8% | 白 10% | `--color-border` |
/// | 强调 | `#1B1B1B` | `#F1F1F1` | `--color-accent` |
///
/// 两处刻意偏离，都在注释里标明原因：
/// 1. 三级文字用 `#6A6A6A`（Astryx 的 `--color-icon-secondary`）而不是
///    `--color-text-disabled` 的 `#919191`——后者白底只有 3.0:1，
///    10pt 正文达不到 WCAG AA；
/// 2. 数据色（上行/下行/CPU/内存）保留 1.1.3 的可读性配色。Astryx neutral
///    是单色系统，全灰会让「上行 vs 下行」只能靠位置区分，属于功能退化。
enum Theme {
    // MARK: - Astryx neutral 语义色

    /// 面板底（`--color-background-body`）
    static let background = dynamic(light: 0xF1F1F1, dark: 0x1B1B1B)
    /// 卡片（`--color-background-surface`）
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x262626)
    /// 次级表面（`--color-background-muted`），用于表头、进度条槽
    static let surfaceMuted = dynamic(light: 0xF1F1F1, dark: 0x1B1B1B)

    static let textPrimary = dynamic(light: 0x000000, dark: 0xFFFFFF)
    static let textSecondary = dynamic(light: 0x474747, dark: 0x9E9E9E)
    /// 三级文字：见类型注释里的偏离说明（白底 5.4:1，达 AA）
    static let textTertiary = dynamic(light: 0x6A6A6A, dark: 0xB9B9B9)

    /// 1px 描边（`--color-border`：黑 8% / 白 10%）
    static let border = dynamicAlpha(light: 0x000000, lightAlpha: 0.08,
                                     dark: 0xFFFFFF, darkAlpha: 0.10)
    /// 强描边（`--color-border-emphasized`），分隔线用
    static let borderStrong = dynamic(light: 0xD4D4D4, dark: 0x525252)
    /// 强调色（`--color-accent`）：主按钮底、选中态
    static let accent = dynamic(light: 0x1B1B1B, dark: 0xF1F1F1)
    /// 强调色上的文字（`--color-on-accent`）
    static let onAccent = dynamic(light: 0xFFFFFF, dark: 0x111111)
    /// 悬停叠加（`--color-overlay-hover`）
    static let hover = dynamicAlpha(light: 0x000000, lightAlpha: 0.04,
                                    dark: 0xFFFFFF, darkAlpha: 0.06)
    /// 卡片投影（`--shadow-low` 的近似：只有一层 2/4，SwiftUI shadow 不便叠三层）
    static let cardShadow = dynamicAlpha(light: 0x000000, lightAlpha: 0.06,
                                         dark: 0x000000, darkAlpha: 0.45)

    // MARK: - 数据色（保留语义色相）

    /// 下行：蓝
    static let down = dynamic(light: 0x0A63E6, dark: 0x4D9AFF)
    /// 上行：琥珀（浅色模式必须加深，原亮琥珀在白底上只有 2.2:1）
    static let up = dynamic(light: 0xB25A00, dark: 0xFFA23E)
    /// CPU 曲线：青绿，刻意避开上下行的蓝/琥珀
    static let cpu = dynamic(light: 0x0F766E, dark: 0x4FD1C5)
    /// 内存曲线：紫罗兰
    static let memory = dynamic(light: 0x6D28D9, dark: 0xA78BFA)
    /// 正常状态点
    static let healthy = dynamic(light: 0x16A34A, dark: 0x34C76D)
    /// 暂停
    static let idle = Color.secondary
    /// 异常
    static let fault = dynamic(light: 0xC0262C, dark: 0xFFAEA7)

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
    /// `0xRRGGBB` → 不透明 sRGB 颜色。Theme 里只写十六进制，和 CSS 令牌一一对应。
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}
