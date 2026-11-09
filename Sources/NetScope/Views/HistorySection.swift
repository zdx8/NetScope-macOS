import AppKit
import SwiftUI

/// 历史视图：今天 / 近 7 天合计、7 天柱状图、今天消耗最多的应用。
struct HistorySection: View {
    let todayTotal: UInt64
    let weekTotal: UInt64
    let topApps: [HistoryStore.AppEntry]
    let dailyTotals: [HistoryStore.DayTotal]

    private let barWidth: CGFloat = 22
    private let barSpacing: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 20) {
                statBlock(title: "今日", value: todayTotal)
                statBlock(title: "近 7 天", value: weekTotal)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)

            VStack(alignment: .leading, spacing: 5) {
                DailyBars(totals: dailyTotals)
                    .frame(height: 46)
                dayAxis
            }
            .padding(.horizontal, 14)

            if topApps.isEmpty {
                VStack(spacing: 5) {
                    Text("暂无历史记录")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("累积到下一次落盘（约 30 秒）后出现")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Text("今日用量")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.bottom, 4)
                    ForEach(topApps) { entry in
                        row(entry)
                    }
                }
                .padding(.horizontal, 14)
            }
        }
        .padding(.vertical, 10)
    }

    /// 日期轴：只标首尾两天，中间留空占位，槽位宽度与柱子对齐
    private var dayAxis: some View {
        HStack(spacing: barSpacing) {
            ForEach(Array(dailyTotals.enumerated()), id: \.offset) { index, day in
                Text(shortDay(day.day, isEdge: index == 0 || index == dailyTotals.count - 1))
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    // fixedSize 让 "10/25" 用自然宽度（22pt 的槽位装不下），
                    // 只有首尾有文字，溢出到相邻空槽不会有视觉问题
                    .fixedSize()
                    .frame(width: barWidth)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func statBlock(title: String, value: UInt64) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(value == 0 ? "—" : ByteFormat.size(value))
                .font(.system(size: 17, weight: .semibold))
                .monospacedDigit()
        }
    }

    private func row(_ entry: HistoryStore.AppEntry) -> some View {
        HStack(spacing: 8) {
            // 历史记录里存的是聚合键，凡是绝对路径都能反查到应用图标
            if let icon = icon(for: entry.key) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 15, height: 15)
            } else {
                Image(systemName: "gearshape.2.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .frame(width: 15, height: 15)
            }
            Text(entry.name)
                .font(.system(size: 11.5))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            Text(ByteFormat.size(entry.total))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }

    private func icon(for key: String) -> NSImage? {
        guard key.hasPrefix("/") else { return nil }
        return NSWorkspace.shared.icon(forFile: key)
    }

    /// 只在首尾显示 "M/D"，中间返回空串占位，保持每根柱子一个等宽槽位
    private func shortDay(_ day: String, isEdge: Bool) -> String {
        guard isEdge, day.count == 10 else { return "" }
        let parts = day.split(separator: "-")
        guard parts.count == 3 else { return "" }
        return "\(parts[1])/\(parts[2])"
    }
}

/// 近 7 天总量柱状图。
///
/// 用 SwiftUI 布局而不是 Canvas：柱宽要固定（Canvas 里按等分算，7 天时每根 43pt 宽，
/// 只有一天有数据时看起来像一块色块），固定宽度 + 居中最省事。
struct DailyBars: View {
    let totals: [HistoryStore.DayTotal]

    var body: some View {
        GeometryReader { geometry in
            let peak = max(totals.map(\.total).max() ?? 0, 1)
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(Array(totals.enumerated()), id: \.offset) { _, day in
                    let ratio = Double(day.total) / Double(peak)
                    let height = day.total > 0
                        ? max(geometry.size.height * CGFloat(ratio), 3)
                        : 1
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(day.total > 0 ? Theme.down.opacity(0.72) : Color.primary.opacity(0.10))
                        .frame(width: 22, height: height)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }
}
