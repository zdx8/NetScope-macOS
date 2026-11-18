import SwiftUI

/// Astryx 的尺度令牌。数值全部来自 astryx 源码，别按感觉改：
/// - 间距是 4pt 阶梯（`--spacing-N` = N × 0.25rem，root 16px）；
/// - 圆角 `inner 6 / element 10 / container 12`（neutral 主题覆盖后的值）；
/// - 字号 `base 14 / sm 12 / xs 10 / lg 17`，标题 semibold。
enum Ax {
    static let s1: CGFloat = 4
    static let s2: CGFloat = 8
    static let s3: CGFloat = 12
    static let s4: CGFloat = 16
    static let s5: CGFloat = 20
    static let s6: CGFloat = 24

    /// 圆角（`--radius-inner` / `--radius-element` / `--radius-container`）
    static let radiusInner: CGFloat = 6
    static let radiusElement: CGFloat = 10
    static let radiusContainer: CGFloat = 12

    /// 三个面板统一尺寸：固定高度是需求的一部分（切换面板时窗口不应跳动），
    /// 列表在内部滚动，而不是把窗口撑高。
    static let panelWidth: CGFloat = 360
    static let panelHeight: CGFloat = 560

    /// 表格行高：14pt 正文 + 上下 10pt，接近 Astryx 的 list item 密度
    static let rowHeight: CGFloat = 34
    static let headerHeight: CGFloat = 46
    static let footerHeight: CGFloat = 42
}

enum AxFont {
    /// display / heading-1（29pt，semibold）
    static let display = Font.system(size: 28, weight: .semibold)
    /// heading-3（17pt）
    static let title = Font.system(size: 17, weight: .semibold)
    /// heading-5（12pt semibold），区块标题
    static let section = Font.system(size: 12, weight: .semibold)
    /// body（14pt）
    static let body = Font.system(size: 13.5)
    /// label（14pt medium）
    static let label = Font.system(size: 13, weight: .medium)
    /// supporting（12pt）
    static let supporting = Font.system(size: 12)
    /// caption（10pt）
    static let caption = Font.system(size: 10)
    /// 数值：等宽数字，避免每秒刷新时左右跳动
    static func number(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight).monospacedDigit()
    }
}

// MARK: - 容器

/// Astryx Card：12pt 圆角、1px `--color-border`、`--shadow-low` 级别的投影。
struct AxCard<Content: View>: View {
    var padding: CGFloat = Ax.s3
    var spacing: CGFloat = Ax.s2
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Ax.radiusContainer, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Ax.radiusContainer, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
        .shadow(color: Theme.cardShadow, radius: 4, x: 0, y: 2)
    }
}

/// 1px 分隔线（`--color-border`）。用 Rectangle 而不是 Divider：
/// Divider 的实际厚度随分辨率变化，与 Astryx 的 1px 描边对不上。
struct AxDivider: View {
    var inset: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(Theme.border)
            .frame(height: 1)
            .padding(.leading, inset)
    }
}

/// 区块标题：12pt semibold + 可选右侧说明（10pt 三级文字）。
struct AxSectionTitle: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Ax.s2) {
            Text(title)
                .font(AxFont.section)
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: Ax.s2)
            if let trailing {
                Text(trailing)
                    .font(AxFont.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .monospacedDigit()
            }
        }
    }
}

/// 胶囊标签（`radius-full`），用于状态与口径说明。
struct AxChip: View {
    let text: String
    var tint: Color = Theme.textSecondary
    var filled: Bool = false

    var body: some View {
        Text(text)
            .font(AxFont.caption)
            .monospacedDigit()
            .foregroundStyle(filled ? Theme.onAccent : tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(
                Capsule(style: .continuous)
                    .fill(filled ? Theme.accent : tint.opacity(0.12))
            )
    }
}

/// 3pt 占比条（Astryx progress 的紧凑形态）。
struct AxMeter: View {
    let fraction: Double
    var color: Color
    var height: CGFloat = 3

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous).fill(Theme.surfaceMuted)
                Capsule(style: .continuous)
                    .fill(color)
                    .frame(width: max(geometry.size.width * min(max(fraction, 0), 1),
                                      fraction > 0 ? height : 0))
            }
        }
        .frame(height: height)
    }
}

// MARK: - 按钮

/// 次级按钮：透明底、悬停叠 4%/6% 黑/白，对应 Astryx 的 ghost button。
struct AxGhostButtonStyle: ButtonStyle {
    var tint: Color = Theme.textSecondary
    var compact: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        AxGhostBody(configuration: configuration, tint: tint, compact: compact)
    }

    private struct AxGhostBody: View {
        let configuration: ButtonStyleConfiguration
        let tint: Color
        let compact: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(AxFont.supporting)
                .foregroundStyle(tint)
                .padding(.horizontal, compact ? 6 : 9)
                .padding(.vertical, compact ? 4 : 6)
                .background(
                    RoundedRectangle(cornerRadius: Ax.radiusElement, style: .continuous)
                        .fill(configuration.isPressed ? Theme.hover.opacity(1.6)
                                                      : (hovering ? Theme.hover : .clear))
                )
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

/// 主按钮：Astryx `--color-accent` 底 + `--color-on-accent` 字。
struct AxPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AxFont.supporting)
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Ax.radiusElement, style: .continuous)
                    .fill(Theme.accent.opacity(configuration.isPressed ? 0.8 : 1))
            )
            .contentShape(Rectangle())
    }
}

/// 行悬停高亮。列表行数量多，只给鼠标所在行铺一层 4% 的叠加，
/// 不做缩放/位移——菜单栏弹窗里任何位移都会被看成抖动。
struct AxHoverBackground: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(hovering ? Theme.hover : .clear)
            .onHover { hovering = $0 }
    }
}

/// 分段控件（Astryx SegmentedControl 的紧凑形态）：
/// 凹槽用 `--color-background-muted`，选中的那一段浮起为 `--color-background-surface`。
struct AxSegmented<Value: Hashable>: View {
    struct Option: Identifiable {
        let value: Value
        let symbol: String
        let label: String

        var id: Value { value }
    }

    let options: [Option]
    @Binding var selection: Value
    var segmentWidth: CGFloat = 30

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options) { option in
                let selected = option.value == selection
                Button {
                    guard !selected else { return }
                    selection = option.value
                } label: {
                    Image(systemName: option.symbol)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                        .frame(width: segmentWidth, height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(selected ? Theme.surface : .clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(selected ? Theme.border : .clear, lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(option.label)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: Ax.radiusElement, style: .continuous)
                .fill(Theme.surfaceMuted)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Ax.radiusElement, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
    }
}
