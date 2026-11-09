import SwiftUI

/// 弹出面板里的一行：图标、名称、下行速率、占比条、上行速率。
struct AppRowView: View {
    let row: AppTrafficRow
    /// 相对本批最快应用的占比（0...1），用于画细进度条
    let fraction: Double

    private let rateWidth: CGFloat = 74

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 8) {
                icon
                    .frame(width: 18, height: 18)

                // 名称与盾牌必须放在同一个 HStack 里：直接和 Spacer 并列时，
                // 长名称会把 Text 撑满可用宽度，盾牌被推到最右边，看起来像独立的一列。
                HStack(spacing: 4) {
                    Text(row.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(row.isAggregate ? Color.secondary : Color.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(row.name)

                    if row.isTunnelClient {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 8.5))
                            .foregroundStyle(.tertiary)
                            .help("VPN 客户端：这里显示的是它在物理链路上的加密流量，"
                                  + "与隧道内应用是同一份数据的两种形态，不要与总量相加")
                    }
                }
                .layoutPriority(1)

                Spacer(minLength: 6)

                Text(ByteFormat.rate(row.down))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(row.down > 0 ? Theme.down : Color.secondary.opacity(0.65))
                    .frame(width: rateWidth, alignment: .trailing)
            }

            HStack(spacing: 6) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule(style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                        Capsule(style: .continuous)
                            .fill(barColor.opacity(row.total > 0 ? 0.55 : 0.14))
                            .frame(width: max(geometry.size.width * min(max(fraction, 0), 1),
                                              fraction > 0 ? 2.5 : 0))
                    }
                }
                .frame(height: 3)

                Text(ByteFormat.rate(row.up))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(row.up > 0 ? Theme.up : Color.secondary.opacity(0.6))
                    .frame(width: rateWidth, alignment: .trailing)
            }
        }
        .padding(.vertical, 2.5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.name)，下行 \(ByteFormat.rate(row.down))，上行 \(ByteFormat.rate(row.up))")
    }

    /// 进度条反映的是「总吞吐占最快应用的比例」，所以颜色跟随主导方向：
    /// 上行占多数的行用琥珀色，避免"蓝色满条 + 下行 0 B/s"这种自相矛盾的显示。
    private var barColor: Color {
        row.up > row.down ? Theme.up : Theme.down
    }

    @ViewBuilder
    private var icon: some View {
        if let image = row.icon {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: row.isAggregate ? "ellipsis.circle" : "gearshape.2.fill")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }
}
