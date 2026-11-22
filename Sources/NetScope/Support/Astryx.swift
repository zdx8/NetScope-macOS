import SwiftUI

/// NetScope 尺度与基础组件令牌。
enum Ax {
    static let s1: CGFloat = 4
    static let s2: CGFloat = 8
    static let s3: CGFloat = 12
    static let s4: CGFloat = 16
    static let s5: CGFloat = 20
    static let s6: CGFloat = 24

    static let radiusInner: CGFloat = 6
    static let radiusElement: CGFloat = 9
    static let radiusContainer: CGFloat = 12

    /// 固定弹窗尺寸：切换视图时窗口不跳动
    static let panelWidth: CGFloat = 360
    static let panelHeight: CGFloat = 560

    static let rowHeight: CGFloat = 34
    static let headerHeight: CGFloat = 46
    static let footerHeight: CGFloat = 42
}

enum AxFont {
    static let display = Font.system(size: 28, weight: .semibold)
    static let title = Font.system(size: 17, weight: .semibold)
    static let section = Font.system(size: 12, weight: .semibold)
    static let body = Font.system(size: 13.5)
    static let label = Font.system(size: 13, weight: .medium)
    static let supporting = Font.system(size: 12)
    static let caption = Font.system(size: 10)

    static func number(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight).monospacedDigit()
    }
}

// MARK: - 容器

/// 标准卡片容器：12pt 圆角 + 1px 精细描边 + 浅色轻阴影（深色纯黑底无投影）
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

/// 统一列表卡片容器：提供可选内嵌表头 + 内部滚动列表区域
struct PanelListCard<Header: View, Content: View>: View {
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, Ax.s3)
                .padding(.vertical, 6)
                .background(Theme.surfaceMuted.opacity(0.45))

            AxDivider()

            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    content
                }
            }
            .scrollIndicators(.automatic)
        }
        .clipShape(RoundedRectangle(cornerRadius: Ax.radiusContainer, style: .continuous))
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

/// 1px 分隔线
struct AxDivider: View {
    var inset: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(Theme.border)
            .frame(height: 1)
            .padding(.leading, inset)
    }
}

/// 区块标题：12pt semibold + 可选右侧说明
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

/// 胶囊标签，用于状态点或标记说明
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
                    .fill(filled ? Theme.accent : tint.opacity(0.14))
            )
    }
}

/// 顶部状态胶囊（带圆点或图标）
struct AxStatusBadge: View {
    let text: String
    let tint: Color
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(tint)
            } else {
                Circle()
                    .fill(tint)
                    .frame(width: 5.5, height: 5.5)
            }
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3.5)
        .background(
            Capsule(style: .continuous)
                .fill(Theme.surfaceMuted)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
    }
}

/// 占比条
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

/// 次级按钮：透明底、悬停叠加
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
                .padding(.horizontal, compact ? 7 : 9)
                .padding(.vertical, compact ? 5 : 6)
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

/// 主按钮
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

/// 行悬停高亮
struct AxHoverBackground: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(hovering ? Theme.hover : .clear)
            .onHover { hovering = $0 }
    }
}

/// 分段控件（图标模式）
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
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(selected ? Theme.surfaceElevated : .clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
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
