import SwiftUI

/// 「系统」资源视图：CPU / 内存 / 磁盘三格紧凑指标条 + 交互式双曲线卡 + 无抖动进程列表。
struct ResourcesTab: View {
    @ObservedObject var monitor: SystemLoadMonitor
    @Binding var sort: ProcessMetric
    var onClose: (ProcessUsageRow) -> Void

    @State private var hoverIndex: Int?

    var body: some View {
        VStack(spacing: 10) {
            metricsCard
            chartCard
            ProcessListSection(rows: monitor.processRows,
                               sort: $sort,
                               accent: sort == .cpu ? Theme.cpu : Theme.memory,
                               onClose: onClose)
        }
        .padding(.horizontal, Ax.s4)
        .padding(.top, Ax.s3)
        .padding(.bottom, Ax.s2)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: - 三格紧凑指标条（CPU / 内存 / 磁盘）

    private var metricsCard: some View {
        AxCard(padding: Ax.s3, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                metricBlock(title: "CPU",
                            symbol: "cpu",
                            color: Theme.cpu,
                            value: monitor.cpuReady ? PercentFormat.text(monitor.cpuPercent) : "—",
                            valueColor: Theme.textPrimary,
                            detail: cpuDetail)
                    .help(cpuDetail)

                Rectangle()
                    .fill(Theme.border)
                    .frame(width: 1, height: 42)
                    .padding(.horizontal, Ax.s2)

                metricBlock(title: "内存",
                            symbol: "memorychip",
                            color: Theme.memory,
                            value: monitor.memory.map { "\(Int($0.percent.rounded()))%" } ?? "—",
                            valueColor: Theme.textPrimary,
                            detail: memoryDetail)
                    .help(memoryDetail)

                Rectangle()
                    .fill(Theme.border)
                    .frame(width: 1, height: 42)
                    .padding(.horizontal, Ax.s2)

                metricBlock(title: "磁盘",
                            symbol: "internaldrive.fill",
                            color: Theme.up,
                            value: diskPercentText,
                            valueColor: diskColor,
                            detail: diskDetail)
                    .help(diskTooltip)
            }
        }
    }

    private func metricBlock(title: String,
                             symbol: String,
                             color: Color,
                             value: String,
                             valueColor: Color,
                             detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2.5) {
            HStack(spacing: 3.5) {
                Image(systemName: symbol)
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(color)
                Text(title)
                    .font(AxFont.caption)
                    .foregroundStyle(Theme.textSecondary)
            }

            Text(value)
                .font(AxFont.number(20))
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .contentTransition(.numericText())

            Text(detail)
                .font(.system(size: 9.5).monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) \(value)，\(detail)")
    }

    private var cpuDetail: String {
        guard let breakdown = monitor.breakdown else { return "采样中…" }
        return "用户 \(Int(breakdown.user.rounded()))% · 系统 \(Int(breakdown.system.rounded()))%"
    }

    private var memoryDetail: String {
        guard let memory = monitor.memory else { return "采样中…" }
        return "\(ByteFormat.size(memory.used)) / \(ByteFormat.size(memory.total))"
    }

    private var diskPercentText: String {
        guard let stats = monitor.stats else { return "—" }
        return "\(Int((stats.diskUsedFraction * 100).rounded()))%"
    }

    private var diskColor: Color {
        guard let stats = monitor.stats else { return Theme.textPrimary }
        return stats.diskUsedFraction > 0.9 ? Theme.fault : Theme.textPrimary
    }

    private var diskDetail: String {
        guard let stats = monitor.stats else { return "读取中…" }
        return "剩余 \(ByteFormat.size(stats.diskFree))"
    }

    private var diskTooltip: String {
        guard let stats = monitor.stats else { return "正在读取磁盘空间" }
        let used = stats.diskTotal >= stats.diskFree ? stats.diskTotal - stats.diskFree : 0
        return "已用 \(ByteFormat.size(used)) / 总计 \(ByteFormat.size(stats.diskTotal))，剩余 \(ByteFormat.size(stats.diskFree))"
    }

    // MARK: - 交互式双曲线

    private var chartCard: some View {
        AxCard(padding: Ax.s3, spacing: Ax.s1) {
            DualLoadChart(cpu: monitor.cpuHistory,
                          memory: monitor.memoryHistory,
                          hoverIndex: $hoverIndex,
                          height: 52)
            chartLegendOrHover
        }
    }

    @ViewBuilder
    private var chartLegendOrHover: some View {
        let cpuPoints = monitor.cpuHistory.points
        let memPoints = monitor.memoryHistory.points
        if let idx = hoverIndex, idx >= 0, idx < cpuPoints.count, idx < memPoints.count {
            let secondsAgo = (cpuPoints.count - 1 - idx) * monitor.sampleSeconds
            let timeText = secondsAgo == 0 ? "现在" : "\(secondsAgo) 秒前"
            HStack(spacing: Ax.s2) {
                Text(timeText)
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 0)
                legend("CPU", color: Theme.cpu, value: "\(Int(cpuPoints[idx].rounded()))%")
                legend("内存", color: Theme.memory, value: "\(Int(memPoints[idx].rounded()))%")
            }
        } else {
            HStack(spacing: Ax.s3) {
                legend("CPU", color: Theme.cpu, value: monitor.cpuReady
                       ? "\(Int(monitor.cpuPercent.rounded()))%" : "—")
                legend("内存", color: Theme.memory, value: monitor.memory
                       .map { "\(Int($0.percent.rounded()))%" } ?? "—")
                Spacer(minLength: Ax.s2)
                Text("近 \(monitor.cpuHistory.capacity * monitor.sampleSeconds) 秒")
                    .font(AxFont.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .monospacedDigit()
            }
        }
    }

    private func legend(_ title: String, color: Color, value: String) -> some View {
        HStack(spacing: Ax.s1) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
            Text(title)
                .font(AxFont.caption)
                .foregroundStyle(Theme.textSecondary)
            Text(value)
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
        }
    }
}

/// CPU 与内存叠在同一张 0–100% 刻度上，支持悬停十字准线读数。
struct DualLoadChart: View {
    let cpu: LoadHistory
    let memory: LoadHistory
    @Binding var hoverIndex: Int?
    var height: CGFloat = 52

    private let scaleWidth: CGFloat = 27

    var body: some View {
        GeometryReader { geometry in
            let plotWidth = max(geometry.size.width - scaleWidth, 1)
            let count = max(cpu.points.count, memory.points.count)
            let slots = max(cpu.capacity, count)

            Canvas { context, size in
                let topInset: CGFloat = 6
                let canvasPlotWidth = max(size.width - scaleWidth, 1)
                let baselineY = size.height - 0.5
                let plotHeight = max(baselineY - topInset, 1)

                func y(_ value: Double) -> CGFloat {
                    let ratio = min(max(value, 0), 100) / 100
                    return baselineY - CGFloat(ratio) * plotHeight
                }

                func grid(_ value: Double, opacity: Double) {
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: y(value)))
                    path.addLine(to: CGPoint(x: canvasPlotWidth, y: y(value)))
                    context.stroke(path, with: .color(Theme.textTertiary.opacity(opacity)),
                                   style: StrokeStyle(lineWidth: 0.5, dash: [1.5, 2.5]))
                }

                grid(0, opacity: 0.30)
                grid(50, opacity: 0.14)
                grid(100, opacity: 0.14)

                func label(_ text: String, at position: CGFloat) {
                    let resolved = context.resolve(
                        Text(text).font(.system(size: 7.5)).foregroundStyle(Theme.textTertiary)
                    )
                    context.draw(resolved, at: CGPoint(x: canvasPlotWidth + 5, y: position), anchor: .leading)
                }
                label("100%", at: topInset + 1)
                label("50%", at: (topInset + baselineY) / 2)
                label("0", at: baselineY - 5)

                func points(for history: LoadHistory) -> [CGPoint] {
                    let pts = history.points
                    guard pts.count >= 2 else { return [] }
                    let stepX = canvasPlotWidth / CGFloat(max(slots - 1, 1))
                    return pts.enumerated().map { idx, val in
                        CGPoint(x: CGFloat(idx) * stepX, y: y(val))
                    }
                }

                func line(_ pts: [CGPoint]) -> Path? {
                    guard pts.count >= 2 else { return nil }
                    var path = Path()
                    for (index, point) in pts.enumerated() {
                        if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                    return path
                }

                let cpuPts = points(for: cpu)
                let memPts = points(for: memory)

                if let cpuLine = line(cpuPts), let last = cpuPts.last {
                    var fill = cpuLine
                    fill.addLine(to: CGPoint(x: last.x, y: size.height))
                    fill.addLine(to: CGPoint(x: 0, y: size.height))
                    fill.closeSubpath()
                    context.fill(fill, with: .linearGradient(
                        Gradient(colors: [Theme.cpu.opacity(0.16), Theme.cpu.opacity(0.01)]),
                        startPoint: CGPoint(x: 0, y: 0),
                        endPoint: CGPoint(x: 0, y: size.height)
                    ))
                    context.stroke(cpuLine, with: .color(Theme.cpu),
                                   style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                }
                if let memLine = line(memPts) {
                    context.stroke(memLine, with: .color(Theme.memory),
                                   style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                }

                if let idx = hoverIndex, count >= 2, idx >= 0, idx < count {
                    let stepX = canvasPlotWidth / CGFloat(max(slots - 1, 1))
                    let x = CGFloat(idx) * stepX
                    var guide = Path()
                    guide.move(to: CGPoint(x: x, y: topInset))
                    guide.addLine(to: CGPoint(x: x, y: baselineY))
                    context.stroke(guide,
                                   with: .color(Theme.textTertiary.opacity(0.45)),
                                   style: StrokeStyle(lineWidth: 1, dash: [2, 2]))

                    if idx < cpuPts.count {
                        drawDot(context: &context, at: cpuPts[idx], color: Theme.cpu)
                    }
                    if idx < memPts.count {
                        drawDot(context: &context, at: memPts[idx], color: Theme.memory)
                    }
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    guard count >= 2, location.x <= plotWidth else {
                        hoverIndex = nil
                        return
                    }
                    let stepX = plotWidth / CGFloat(max(slots - 1, 1))
                    let raw = Int((location.x / max(stepX, 0.1)).rounded())
                    hoverIndex = (raw >= 0 && raw < count) ? raw : nil
                case .ended:
                    hoverIndex = nil
                }
            }
        }
        .frame(height: height)
    }

    private func drawDot(context: inout GraphicsContext, at point: CGPoint, color: Color) {
        let outer = CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)
        let inner = CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)
        context.fill(Path(ellipseIn: outer), with: .color(Theme.surface))
        context.fill(Path(ellipseIn: inner), with: .color(color))
    }
}
