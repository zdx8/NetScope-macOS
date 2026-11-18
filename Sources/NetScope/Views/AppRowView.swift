import SwiftUI

/// 网络面板里的一行：图标、名称、占比条、上行、下行（上行永远在前，与总览一致）。
///
/// 行高 36pt、两条数值列等宽右对齐 —— 数值在 `0 B/s` / `1.2 MB/s` 之间跳变时
/// 列宽不变，右侧不会跟着呼吸。
struct AppRowView: View {
    let row: AppTrafficRow
    /// 相对本批最快应用的占比（0...1），用于画细进度条
    let fraction: Double

    private let rateWidth: CGFloat = 64

    var body: some View {
        HStack(spacing: Ax.s2) {
            icon
                .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Ax.s1) {
                    Text(row.name)
                        .font(AxFont.label)
                        .foregroundStyle(row.isAggregate ? Theme.textSecondary : Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(row.name)

                    if row.isTunnelClient {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 8.5))
                            .foregroundStyle(Theme.up)
                            .help("VPN 客户端：这里显示的是它在物理链路上的加密流量，"
                                  + "与隧道内应用是同一份数据的两种形态，不要与总量相加")
                    }
                }

                AxMeter(fraction: min(max(fraction, 0), 1), color: barColor, height: 2.5)
                    .frame(maxWidth: 120)
            }

            Spacer(minLength: Ax.s1)

            Text(ByteFormat.rate(row.up))
                .font(AxFont.number(11.5, weight: .medium))
                .foregroundStyle(row.up > 0 ? Theme.up : Theme.textTertiary)
                .frame(width: rateWidth, alignment: .trailing)

            Text(ByteFormat.rate(row.down))
                .font(AxFont.number(11.5, weight: .medium))
                .foregroundStyle(row.down > 0 ? Theme.down : Theme.textTertiary)
                .frame(width: rateWidth, alignment: .trailing)
        }
        .padding(.horizontal, Ax.s3)
        .frame(height: 36)
        .modifier(AxHoverBackground())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.name)，上行 \(ByteFormat.rate(row.up))，下行 \(ByteFormat.rate(row.down))")
    }

    /// 进度条反映「总吞吐占最快应用的比例」，颜色跟随主导方向：
    /// 上行占多数的行用琥珀色，避免「蓝色满条 + 下行 0 B/s」这种自相矛盾的显示。
    private var barColor: Color {
        if row.total <= 0 { return Theme.textTertiary }
        return row.up > row.down ? Theme.up : Theme.down
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
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
        }
    }
}
