import SwiftUI

/// 「清理释放」页：CPU 与内存合并成一块详情（1.1.7 之前是两个独立弹窗）。
///
/// 结构对齐参考图：上方双指标卡（CPU / 内存并排）→ 双曲线卡片 → 程序列表。
/// 程序列表支持「按 CPU / 按内存」两种排序，鼠标移上去可关闭该应用。
struct CleanupTab: View {
    @ObservedObject var monitor: SystemLoadMonitor
    @Binding var sort: ProcessMetric
    var onClose: (ProcessUsageRow) -> Void

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

    // MARK: - 双指标

    private var metricsCard: some View {
        AxCard(padding: Ax.s3) {
            HStack(alignment: .top, spacing: 0) {
                metricBlock(title: "CPU",
                            symbol: "cpu",
                            color: Theme.cpu,
                            value: monitor.cpuReady ? PercentFormat.text(monitor.cpuPercent) : "—",
                            detail: cpuDetail)
                Rectangle()
                    .fill(Theme.border)
                    .frame(width: 1, height: 46)
                    .padding(.horizontal, Ax.s3)
                metricBlock(title: "内存",
                            symbol: "memorychip",
                            color: Theme.memory,
                            value: monitor.memory.map { "\(Int($0.percent.rounded()))%" } ?? "—",
                            detail: memoryDetail)
            }
        }
    }

    private func metricBlock(title: String, symbol: String, color: Color,
                             value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: Ax.s1) {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(color)
                Text(title)
                    .font(AxFont.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Text(value)
                .font(AxFont.number(24))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
            Text(detail)
                .font(AxFont.caption)
                .foregroundStyle(Theme.textTertiary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) \(value)，\(detail)")
    }

    private var cpuDetail: String {
        guard let breakdown = monitor.breakdown else { return "首次采样中" }
        return "用户 \(Int(breakdown.user.rounded()))% · 系统 \(Int(breakdown.system.rounded()))%"
    }

    private var memoryDetail: String {
        guard let memory = monitor.memory else { return "首次采样中" }
        return "\(ByteFormat.size(memory.used)) / \(ByteFormat.size(memory.total))"
    }

    // MARK: - 双曲线

    private var chartCard: some View {
        AxCard(padding: Ax.s3, spacing: Ax.s1) {
            DualLoadChart(cpu: monitor.cpuHistory,
                          memory: monitor.memoryHistory,
                          height: 52)
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

/// CPU 与内存叠在同一张 0–100% 刻度上：两条线都天然是百分比，
/// 分开画两张卡会浪费纵向空间，叠起来才看得出「CPU 尖峰时内存是否跟着涨」。
struct DualLoadChart: View {
    let cpu: LoadHistory
    let memory: LoadHistory
    var height: CGFloat = 52

    private let scaleWidth: CGFloat = 27

    var body: some View {
        Canvas { context, size in
            let topInset: CGFloat = 7
            let plotWidth = max(size.width - scaleWidth, 1)
            let baselineY = size.height - 0.5
            let plotHeight = max(baselineY - topInset, 1)

            func y(_ value: Double) -> CGFloat {
                let ratio = min(max(value, 0), 100) / 100
                return baselineY - CGFloat(ratio) * plotHeight
            }

            func grid(_ value: Double, opacity: Double) {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y(value)))
                path.addLine(to: CGPoint(x: plotWidth, y: y(value)))
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
                context.draw(resolved, at: CGPoint(x: plotWidth + 5, y: position), anchor: .leading)
            }
            label("100%", at: topInset + 1)
            label("50%", at: (topInset + baselineY) / 2)
            label("0", at: baselineY - 5)

            func line(_ history: LoadHistory) -> Path? {
                let points = history.points
                guard points.count >= 2 else { return nil }
                let slots = max(history.capacity, points.count)
                let stepX = plotWidth / CGFloat(max(slots - 1, 1))
                var path = Path()
                for (index, value) in points.enumerated() {
                    let point = CGPoint(x: CGFloat(index) * stepX, y: y(value))
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                return path
            }

            // 只给 CPU 铺一层很淡的渐变：两条都填色会互相盖住
            if let cpuLine = line(cpu) {
                var fill = cpuLine
                fill.addLine(to: CGPoint(x: plotWidth, y: size.height))
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
            if let memoryLine = line(memory) {
                context.stroke(memoryLine, with: .color(Theme.memory),
                               style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(height: height)
    }
}
