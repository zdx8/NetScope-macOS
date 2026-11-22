import SwiftUI

/// 流量统计卡片：实时 / 日 / 周 / 月四档切换 + 统一摘要/图例行 + 交互式平滑双线图。
struct TrafficChartCard: View {
    @ObservedObject var engine: MonitorEngine
    @ObservedObject var router: PanelRouter

    @State private var hoverIndex: Int?

    var body: some View {
        AxCard(padding: Ax.s3, spacing: Ax.s2) {
            headerRow

            if router.trafficRange == .live {
                liveSection
            } else if historyHasData {
                historySection
            } else {
                historyEmpty
            }
        }
    }

    // MARK: - 标题与四档切换

    private var headerRow: some View {
        HStack(spacing: Ax.s2) {
            Text("流量统计")
                .font(AxFont.section)
                .foregroundStyle(Theme.textSecondary)

            Spacer(minLength: Ax.s2)

            HStack(spacing: 2) {
                ForEach([TrafficRange.live, .day, .week, .month], id: \.self) { option in
                    rangeChip(option)
                }
            }
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: Ax.radiusInner, style: .continuous)
                    .fill(Theme.surfaceMuted)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Ax.radiusInner, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
        }
    }

    private func rangeChip(_ option: TrafficRange) -> some View {
        let selected = router.trafficRange == option
        return Button {
            guard !selected else { return }
            hoverIndex = nil
            router.trafficRange = option
            if let granularity = option.granularity {
                engine.refreshHistory(range: granularity)
            }
        } label: {
            Text(option.title)
                .font(.system(size: 10.5, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2.5)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(selected ? Theme.surfaceElevated : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(selected ? Theme.border : Color.clear, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(rangeHelp(option))
    }

    private func rangeHelp(_ option: TrafficRange) -> String {
        switch option {
        case .live: return "当前每秒速率（近 60 秒曲线）"
        case .day: return "过去 24 小时，5 分钟平均值"
        case .week: return "过去 7 天，30 分钟平均值"
        case .month: return "过去 30 天，2 小时平均值"
        }
    }

    // MARK: - 实时档

    private var liveSection: some View {
        let points = engine.history.points
        let up = points.map(\.up)
        let down = points.map(\.down)
        let peak = max(up.max() ?? 0, down.max() ?? 0, 1)

        return VStack(spacing: Ax.s1) {
            liveSummaryOrHover(up: up, down: down, peak: peak)
            SmoothRateChart(up: up, down: down, hoverIndex: $hoverIndex)
            chartFooter(startLabel: "60 秒前", endLabel: "现在")
        }
    }

    @ViewBuilder
    private func liveSummaryOrHover(up: [Double], down: [Double], peak: Double) -> some View {
        if let idx = hoverIndex, idx >= 0, idx < up.count, idx < down.count {
            let secondsAgo = (up.count - 1 - idx) * Settings.shared.sampleInterval
            let timeText = secondsAgo == 0 ? "现在" : "\(secondsAgo) 秒前"
            hoverReadoutRow(time: timeText, upRate: up[idx], downRate: down[idx])
        } else {
            HStack(spacing: Ax.s3) {
                legendDot("上行", color: Theme.up)
                legendDot("下行", color: Theme.down)
                Spacer(minLength: 0)
                Text("峰值 \(ByteFormat.rate(peak))")
                    .font(AxFont.caption)
                    .monospacedDigit()
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(height: 16)
        }
    }

    // MARK: - 历史档

    private var historyHasData: Bool {
        engine.historyAvailable && engine.historySeries.contains { $0.total > 0 }
    }

    private var bucketInterval: Double {
        router.trafficRange.granularity?.seconds ?? 300
    }

    private var historyRates: (up: [Double], down: [Double]) {
        let interval = bucketInterval
        return (engine.historySeries.map { Double($0.bytesOut) / interval },
                engine.historySeries.map { Double($0.bytesIn) / interval })
    }

    private var historyTotals: (up: UInt64, down: UInt64) {
        (engine.historySeries.reduce(UInt64(0)) { $0 &+ $1.bytesOut },
         engine.historySeries.reduce(UInt64(0)) { $0 &+ $1.bytesIn })
    }

    private var historySection: some View {
        let rates = historyRates
        let series = engine.historySeries
        let peak = max(rates.up.max() ?? 0, rates.down.max() ?? 0, 1)

        return VStack(spacing: Ax.s1) {
            historySummaryOrHover(rates: rates, series: series, peak: peak)
            SmoothRateChart(up: rates.up, down: rates.down, hoverIndex: $hoverIndex)
            chartFooter(startLabel: timeLabel(series.first?.time),
                        endLabel: timeLabel(series.last?.time))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(router.trafficRange.rangeLabel) 上行 \(ByteFormat.size(historyTotals.up))，下行 \(ByteFormat.size(historyTotals.down))")
    }

    @ViewBuilder
    private func historySummaryOrHover(rates: (up: [Double], down: [Double]),
                                       series: [HistoryStore.SamplePoint],
                                       peak: Double) -> some View {
        if let idx = hoverIndex, idx >= 0, idx < series.count {
            hoverReadoutRow(time: detailedTimeLabel(series[idx].time),
                            upRate: rates.up[idx],
                            downRate: rates.down[idx])
        } else {
            let totals = historyTotals
            // 统一「先上行后下行」阅读顺序
            HStack(spacing: Ax.s2) {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.up)
                    Text(ByteFormat.size(totals.up))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                }
                HStack(spacing: 3) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.down)
                    Text(ByteFormat.size(totals.down))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                }
                Spacer(minLength: 0)
                Text("\(router.trafficRange.rangeLabel) · 峰值 \(ByteFormat.rate(peak))")
                    .font(AxFont.caption)
                    .monospacedDigit()
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            .frame(height: 16)
        }
    }

    // MARK: - 共用小组件

    private func hoverReadoutRow(time: String, upRate: Double, downRate: Double) -> some View {
        HStack(spacing: Ax.s2) {
            Text(time)
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)

            Spacer(minLength: 0)

            HStack(spacing: 3) {
                Circle().fill(Theme.up).frame(width: 5, height: 5)
                Text("↑ \(ByteFormat.rate(upRate))")
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.up)
            }

            HStack(spacing: 3) {
                Circle().fill(Theme.down).frame(width: 5, height: 5)
                Text("↓ \(ByteFormat.rate(downRate))")
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.down)
            }
        }
        .frame(height: 16)
    }

    private func legendDot(_ title: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 5.5, height: 5.5)
            Text(title)
                .font(AxFont.caption)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var historyEmpty: some View {
        VStack(spacing: Ax.s1) {
            Spacer(minLength: 0)
            HStack(spacing: Ax.s2) {
                Image(systemName: "chart.xyaxis.line")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textTertiary)
                Text(engine.historyAvailable
                     ? "该时间段暂无流量记录 · 按 5 分钟桶持续累积"
                     : "历史库不可用，无法统计")
                    .font(AxFont.supporting)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        // 与有数据时的「摘要行(16) + 曲线(72) + 时间脚标(12) + 间距(8)」保持等高，消除切档跳动
        .frame(maxWidth: .infinity)
        .frame(height: 108)
    }

    private func chartFooter(startLabel: String, endLabel: String) -> some View {
        HStack {
            Text(startLabel)
                .font(.system(size: 8.5))
                .monospacedDigit()
                .foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 0)
            Text(endLabel)
                .font(.system(size: 8.5))
                .monospacedDigit()
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(height: 12)
    }

    private func timeLabel(_ time: TimeInterval?) -> String {
        guard let time else { return "" }
        let date = Date(timeIntervalSince1970: time)
        let comps = Calendar.current.dateComponents([.month, .day, .hour, .minute], from: date)
        switch router.trafficRange {
        case .day:
            return String(format: "%02d:%02d", comps.hour ?? 0, comps.minute ?? 0)
        case .week, .month:
            return "\(comps.month ?? 0)/\(comps.day ?? 0)"
        case .live:
            return ""
        }
    }

    private func detailedTimeLabel(_ time: TimeInterval) -> String {
        let date = Date(timeIntervalSince1970: time)
        let comps = Calendar.current.dateComponents([.month, .day, .hour, .minute], from: date)
        switch router.trafficRange {
        case .day:
            return String(format: "%02d:%02d", comps.hour ?? 0, comps.minute ?? 0)
        case .week, .month:
            return String(format: "%d/%d %02d:%02d",
                          comps.month ?? 0, comps.day ?? 0,
                          comps.hour ?? 0, comps.minute ?? 0)
        case .live:
            return ""
        }
    }
}

/// 交互式平滑双线速率曲线：Catmull-Rom 贝塞尔平滑 + 悬停十字准线与高光节点。
private struct SmoothRateChart: View {
    let up: [Double]
    let down: [Double]
    @Binding var hoverIndex: Int?

    static let chartHeight: CGFloat = 72

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let count = max(up.count, down.count)

            Canvas { context, size in
                let topInset: CGFloat = 6
                let baselineY = size.height - 1
                let plotHeight = max(baselineY - topInset, 1)
                let peak = max(down.max() ?? 0, up.max() ?? 0, 1)

                func y(_ value: Double) -> CGFloat {
                    let ratio = min(max(value / peak, 0), 1)
                    return baselineY - CGFloat(ratio) * plotHeight
                }

                // 50% 淡虚线参考 + 底部分隔基线
                let midY = topInset + plotHeight * 0.5
                var midLine = Path()
                midLine.move(to: CGPoint(x: 0, y: midY))
                midLine.addLine(to: CGPoint(x: size.width, y: midY))
                context.stroke(midLine,
                               with: .color(Theme.textTertiary.opacity(0.14)),
                               style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))

                var baseline = Path()
                baseline.move(to: CGPoint(x: 0, y: baselineY))
                baseline.addLine(to: CGPoint(x: size.width, y: baselineY))
                context.stroke(baseline, with: .color(Theme.border), lineWidth: 0.75)

                func points(for values: [Double]) -> [CGPoint] {
                    guard values.count >= 2 else { return [] }
                    let stepX = size.width / CGFloat(max(values.count - 1, 1))
                    return values.enumerated().map { idx, val in
                        CGPoint(x: CGFloat(idx) * stepX, y: y(val))
                    }
                }

                let downPoints = points(for: down)
                let upPoints = points(for: up)

                if let downPath = smoothPath(downPoints, minY: topInset, maxY: baselineY) {
                    var fill = downPath
                    fill.addLine(to: CGPoint(x: size.width, y: baselineY))
                    fill.addLine(to: CGPoint(x: 0, y: baselineY))
                    fill.closeSubpath()
                    context.fill(fill, with: .linearGradient(
                        Gradient(colors: [Theme.down.opacity(0.18), Theme.down.opacity(0.01)]),
                        startPoint: CGPoint(x: 0, y: topInset),
                        endPoint: CGPoint(x: 0, y: baselineY)
                    ))
                    context.stroke(downPath, with: .color(Theme.down),
                                   style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                }

                if let upPath = smoothPath(upPoints, minY: topInset, maxY: baselineY) {
                    context.stroke(upPath, with: .color(Theme.up),
                                   style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                }

                // 悬停十字准线与高光点
                if let idx = hoverIndex, count >= 2, idx >= 0, idx < count {
                    let stepX = size.width / CGFloat(count - 1)
                    let x = CGFloat(idx) * stepX

                    var guide = Path()
                    guide.move(to: CGPoint(x: x, y: topInset))
                    guide.addLine(to: CGPoint(x: x, y: baselineY))
                    context.stroke(guide,
                                   with: .color(Theme.textTertiary.opacity(0.45)),
                                   style: StrokeStyle(lineWidth: 1, dash: [2, 2]))

                    if idx < downPoints.count {
                        drawDot(context: &context, at: downPoints[idx], color: Theme.down)
                    }
                    if idx < upPoints.count {
                        drawDot(context: &context, at: upPoints[idx], color: Theme.up)
                    }
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    guard count >= 2 else {
                        hoverIndex = nil
                        return
                    }
                    let ratio = min(max(location.x / width, 0), 1)
                    hoverIndex = Int((ratio * CGFloat(count - 1)).rounded())
                case .ended:
                    hoverIndex = nil
                }
            }
        }
        .frame(height: Self.chartHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("流量速率曲线，上行橙线，下行蓝线")
    }

    private func drawDot(context: inout GraphicsContext, at point: CGPoint, color: Color) {
        let outer = CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7)
        let inner = CGRect(x: point.x - 2.2, y: point.y - 2.2, width: 4.4, height: 4.4)
        context.fill(Path(ellipseIn: outer), with: .color(Theme.surface))
        context.fill(Path(ellipseIn: inner), with: .color(color))
    }

    /// Catmull-Rom 样条转三阶贝塞尔曲线，钳制控制点 Y 防止过冲越过基线。
    private func smoothPath(_ pts: [CGPoint], minY: CGFloat, maxY: CGFloat) -> Path? {
        guard pts.count >= 2 else { return nil }
        var path = Path()
        path.move(to: pts[0])
        if pts.count == 2 {
            path.addLine(to: pts[1])
            return path
        }
        let clampY: (CGFloat) -> CGFloat = { min(max($0, minY), maxY) }
        for i in 0..<(pts.count - 1) {
            let p0 = i > 0 ? pts[i - 1] : pts[i]
            let p1 = pts[i]
            let p2 = pts[i + 1]
            let p3 = i + 2 < pts.count ? pts[i + 2] : p2

            let cp1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6,
                              y: clampY(p1.y + (p2.y - p0.y) / 6))
            let cp2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6,
                              y: clampY(p2.y - (p3.y - p1.y) / 6))
            path.addCurve(to: p2, control1: cp1, control2: cp2)
        }
        return path
    }
}
