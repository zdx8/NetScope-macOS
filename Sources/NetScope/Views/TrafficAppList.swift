import SwiftUI

/// 应用流量排行列表：使用统一 `PanelListCard` 承载实时速率排行或历史区间累计排行。
struct TrafficAppList: View {
    @ObservedObject var engine: MonitorEngine
    @ObservedObject var router: PanelRouter

    var body: some View {
        PanelListCard {
            HStack(spacing: Ax.s2) {
                Text(router.trafficRange == .live ? "应用" : "应用 · \(router.trafficRange.rangeLabel)")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("上行").frame(width: 64, alignment: .trailing)
                Text("下行").frame(width: 64, alignment: .trailing)
            }
            .font(AxFont.caption)
            .foregroundStyle(Theme.textTertiary)
        } content: {
            if router.trafficRange == .live {
                liveContent
            } else {
                historyContent
            }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - 实时档列表

    @ViewBuilder
    private var liveContent: some View {
        if engine.rows.isEmpty {
            liveEmptyState
        } else {
            ForEach(engine.rows) { row in
                AppRowView(row: row, fraction: fraction(for: row))
                if row.id != engine.rows.last?.id {
                    AxDivider(inset: Ax.s3 + 24)
                }
            }
        }
    }

    private func fraction(for row: AppTrafficRow) -> Double {
        guard engine.peakRowTotal > 0 else { return 0 }
        return row.total / engine.peakRowTotal
    }

    private var liveEmptyState: some View {
        VStack(spacing: Ax.s2) {
            if case .failed = engine.status {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.fault)
                Text("无法读取网络计数")
                    .font(AxFont.supporting)
                    .foregroundStyle(Theme.textSecondary)
                Button("重试") { engine.start() }
                    .buttonStyle(AxPrimaryButtonStyle())
            } else if engine.sampleCount == 0 {
                ProgressView().controlSize(.small)
                Text("正在采集…")
                    .font(AxFont.supporting)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.textTertiary)
                Text("当前没有活跃网络流量")
                    .font(AxFont.supporting)
                    .foregroundStyle(Theme.textSecondary)
                Text("系统级守护进程的后台同步可能仍在进行")
                    .font(AxFont.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 52)
    }

    // MARK: - 历史档列表

    @ViewBuilder
    private var historyContent: some View {
        if engine.historyTopApps.isEmpty {
            VStack(spacing: Ax.s2) {
                Image(systemName: "app.dashed")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textTertiary)
                Text("该时间段没有应用流量记录")
                    .font(AxFont.supporting)
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 52)
        } else {
            ForEach(engine.historyTopApps) { entry in
                HistoryAppRow(entry: entry, peak: historyPeakTotal)
                if entry.id != engine.historyTopApps.last?.id {
                    AxDivider(inset: Ax.s3 + 24)
                }
            }
        }
    }

    private var historyPeakTotal: UInt64 {
        engine.historyTopApps.map(\.total).max() ?? 0
    }
}

/// 历史档应用行：图标 + 名称 + 占比条 + 该时间段累计上行/下行（先上行后下行）。
private struct HistoryAppRow: View {
    let entry: HistoryStore.AppEntry
    let peak: UInt64

    private let rateWidth: CGFloat = 64

    var body: some View {
        HStack(spacing: Ax.s2) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .font(AxFont.label)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(entry.name)

                AxMeter(fraction: fraction, color: barColor, height: 2.5)
                    .frame(maxWidth: 120)
            }

            Spacer(minLength: Ax.s1)

            Text(ByteFormat.size(entry.bytesOut))
                .font(AxFont.number(11.5, weight: .medium))
                .foregroundStyle(entry.bytesOut > 0 ? Theme.up : Theme.textTertiary)
                .frame(width: rateWidth, alignment: .trailing)

            Text(ByteFormat.size(entry.bytesIn))
                .font(AxFont.number(11.5, weight: .medium))
                .foregroundStyle(entry.bytesIn > 0 ? Theme.down : Theme.textTertiary)
                .frame(width: rateWidth, alignment: .trailing)
        }
        .padding(.horizontal, Ax.s3)
        .frame(height: 36)
        .modifier(AxHoverBackground())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.name)，上行 \(ByteFormat.size(entry.bytesOut))，下行 \(ByteFormat.size(entry.bytesIn))")
    }

    private var fraction: Double {
        guard peak > 0 else { return 0 }
        return Double(entry.total) / Double(peak)
    }

    private var barColor: Color {
        entry.bytesIn >= entry.bytesOut ? Theme.down : Theme.up
    }

    private var icon: NSImage {
        let image = NSWorkspace.shared.icon(forFile: entry.key)
        return image.size.width > 0 ? image : NSWorkspace.shared.icon(for: .unixExecutable)
    }
}
