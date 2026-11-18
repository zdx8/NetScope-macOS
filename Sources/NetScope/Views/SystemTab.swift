import SwiftUI

/// 「系统功能」页：系统区块（磁盘占用含可用空间 ｜ 本机速率，图标标注）
/// + 流量统计（实时 / 日 / 周 / 月四档曲线）+ 应用列表。
///
/// 流量统计的四档：
/// - **实时**：当前每秒速率的 60 点曲线（引擎内存里的 `RateHistory`，不查库）；
/// - **日**：过去 24 小时，5 分钟平均值（288 点，查 5 分钟桶层）；
/// - **周**：过去 7 天，30 分钟平均值（336 点，查 30 分钟桶层）；
/// - **月**：过去 30 天，2 小时平均值（360 点，查 2 小时桶层）。
///
/// 图表下方的应用列表跟着档位切数据源：实时档是当前速率排行（引擎每秒刷新），
/// 历史档是该时间段内每应用的累计流量排行（SQLite 聚合）。
///
/// 为什么这一格放磁盘与速率而不是温度/风扇：读 CPU 温度、风扇转速必须走 AppleSMC，
/// 实测本机 `IOServiceOpen("AppleSMC")` 能打开，但所有键（连 `#KEY`）都返回 0x84
/// 「键不可读」—— 没有特权助手就拿不到，宁可不显示也不摆假格子。
/// 散热与开机时长随之撤下（`SystemStats` 仍在采样，自检覆盖，后续要恢复直接接回）。
/// 样式（1.3.1 定稿）对齐清理释放页的「CPU / 内存」指标卡：彩色图标 + 标签一行、
/// 24pt 数值、灰色明细；磁盘占用管「存储还剩多少」（可用空间并入其明细行），
/// 本机速率管「此刻网上有多少」（上行在上、下行在下）。
struct SystemTab: View {
    @ObservedObject var engine: MonitorEngine
    @ObservedObject var settings: Settings
    @ObservedObject var router: PanelRouter

    var body: some View {
        VStack(spacing: 10) {
            systemCard
            trafficCard
            appList
        }
        .padding(.horizontal, Ax.s4)
        .padding(.top, Ax.s3)
        .padding(.bottom, Ax.s2)
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear {
            // 面板每次重新装配时按当前档位刷一次历史（实时档不查库）
            if let granularity = router.trafficRange.granularity {
                engine.refreshHistory(range: granularity)
            }
        }
    }

    // MARK: - 系统区块

    private var systemCard: some View {
        AxCard(padding: Ax.s3, spacing: Ax.s2) {
            HStack(alignment: .top, spacing: 0) {
                diskStatColumn
                Rectangle()
                    .fill(Theme.border)
                    // 两列等高（右列两条 24pt 速率决定行高），分隔线几乎通高、上下略缩进
                    .frame(width: 1, height: 74)
                    .padding(.horizontal, Ax.s3)
                rateStatColumn
            }
        }
    }

    /// 左右配比不是对半：磁盘列内容短（「92%」「39.2 GB / 494 GB」），速率列是两条
    /// 24pt 速率行，长得多。对半分的结果就是左边一截空白、右边顶到卡片边——
    /// 分隔线看着偏左、两列「大小不协调」。面板宽是定值 360，直接按内容配比
    /// 42/58 定宽最稳，速率长串也有从容的伸展空间。
    private var diskColumnWidth: CGFloat {
        let inner = Ax.panelWidth - Ax.s3 * 2      // 卡片左右内边距
        let dividerBlock = 1 + Ax.s3 * 2           // 分隔线 + 两侧间距
        return ((inner - dividerBlock) * 0.42).rounded(.down)
    }

    /// 左列：磁盘占用（可用空间并入此列的明细行）。样式对齐清理释放页的
    /// 「CPU / 内存」指标卡：彩色图标 + 标签一行、24pt 数值、灰色明细。
    /// 图标着色用 Theme.up（琥珀）：数据色里 teal=CPU、violet=内存、blue=网络，
    /// 磁盘取琥珀正好不与它们撞车（琥珀同时是上行色，但两列分属两侧，不会混）。
    private var diskStatColumn: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: Ax.s1) {
                Image(systemName: "internaldrive.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.up)
                Text("磁盘占用")
                    .font(AxFont.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            // 占比在标签与明细之间**上下居中**：包一层弹性高度框（列已定高，
            // 弹性框只分到标签/明细之外的剩余空间，不会贪婪扩张），
            // 左列三行呈「标签在上、数值居中、明细沉底」的节奏。
            Text(diskPercentText)
                .font(AxFont.number(24))
                .foregroundStyle(diskColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
                .frame(maxHeight: .infinity, alignment: .center)
            Text("\(diskFreeText) / \(diskTotalText)")
                .font(AxFont.caption)
                .monospacedDigit()
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        // 高度 77 ≈ 右列三条行高之和（标签 ~13 + 3 + 速率 29 + 3 + 速率 29）。
        // 若与右列差 1-2pt，由卡片高度取较大者吸收，肉眼不可见。
        .frame(width: diskColumnWidth, height: 77, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("磁盘占用 \(diskPercentText)，可用 \(diskFreeText)，共 \(diskTotalText)")
    }

    /// 右列：本机速率。上行在上、下行在下，各自带语义色箭头，数值 24pt。
    private var rateStatColumn: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: Ax.s1) {
                Image(systemName: "network")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.down)
                Text("本机速率")
                    .font(AxFont.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            rateLine(systemImage: "arrow.up", color: Theme.up, value: ByteFormat.rate(engine.totalUp))
            rateLine(systemImage: "arrow.down", color: Theme.down, value: ByteFormat.rate(engine.totalDown))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("本机速率 上行 \(ByteFormat.rate(engine.totalUp))，下行 \(ByteFormat.rate(engine.totalDown))")
    }

    private func rateLine(systemImage: String, color: Color, value: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(color)
            Text(value)
                .font(AxFont.number(24))
                .monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
        }
    }

    private var monitor: SystemLoadMonitor? { engine.systemLoad }

    private var diskPercentText: String {
        guard let stats = monitor?.stats else { return "—" }
        return "\(Int((stats.diskUsedFraction * 100).rounded()))%"
    }

    private var diskColor: Color {
        guard let stats = monitor?.stats else { return Theme.textPrimary }
        return stats.diskUsedFraction > 0.9 ? Theme.fault : Theme.textPrimary
    }

    private var diskFreeText: String {
        monitor?.stats.map { ByteFormat.size($0.diskFree) } ?? "—"
    }

    private var diskTotalText: String {
        monitor?.stats.map { ByteFormat.size($0.diskTotal) } ?? "—"
    }

    // MARK: - 流量统计

    /// 实时 / 日 / 周 / 月曲线。历史档的点是「桶内累计 ÷ 桶宽」的平均速率。
    private var trafficCard: some View {
        AxCard(padding: Ax.s3, spacing: Ax.s2) {
            HStack(spacing: Ax.s2) {
                Text("流量统计")
                    .font(AxFont.section)
                    .foregroundStyle(Theme.textSecondary)
                Spacer(minLength: Ax.s2)

                // 档位胶囊，与程序列表的「按 CPU｜按内存」同一套样式
                HStack(spacing: 2) {
                    ForEach([TrafficRange.live, .day, .week, .month],
                            id: \.self) { option in
                        rangeChip(option)
                    }
                }
                .padding(2)
                .background(
                    RoundedRectangle(cornerRadius: Ax.radiusInner, style: .continuous)
                        .fill(Theme.surfaceMuted)
                )
            }

            if router.trafficRange == .live {
                liveChartSection
            } else if historyHasData {
                historyChartSection
            } else {
                historyEmpty
            }
        }
    }

    private func rangeChip(_ option: TrafficRange) -> some View {
        let selected = router.trafficRange == option
        return Button {
            guard !selected else { return }
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
                        .fill(selected ? Theme.surface : Color.clear)
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

    // MARK: 实时档

    private var liveChartSection: some View {
        let points = engine.history.points
        let down = points.map(\.down)
        let up = points.map(\.up)
        return VStack(spacing: Ax.s1) {
            RateLinesChart(down: down, up: up)
            chartFooter(startLabel: "60 秒前", endLabel: "现在")
        }
    }

    // MARK: 历史档

    private var historyHasData: Bool {
        engine.historyAvailable && engine.historySeries.contains { $0.total > 0 }
    }

    private var bucketInterval: Double {
        router.trafficRange.granularity?.seconds ?? 300
    }

    private var historyRates: (down: [Double], up: [Double]) {
        let interval = bucketInterval
        return (engine.historySeries.map { Double($0.bytesIn) / interval },
                engine.historySeries.map { Double($0.bytesOut) / interval })
    }

    private var historyChartSection: some View {
        let rates = historyRates
        let series = engine.historySeries
        let range = router.trafficRange
        return VStack(spacing: Ax.s1) {
            summaryRow
            RateLinesChart(down: rates.down, up: rates.up)
            chartFooter(startLabel: timeLabel(series.first?.time),
                        endLabel: timeLabel(series.last?.time))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(range.rangeLabel)下行 \(ByteFormat.size(historyTotals.in))，上行 \(ByteFormat.size(historyTotals.out))")
    }

    private var historyTotals: (in: UInt64, out: UInt64) {
        (engine.historySeries.reduce(UInt64(0)) { $0 &+ $1.bytesIn },
         engine.historySeries.reduce(UInt64(0)) { $0 &+ $1.bytesOut })
    }

    /// 历史档汇总：当前范围 ↓总量 ↑总量，右端是范围文案
    private var summaryRow: some View {
        let totals = historyTotals
        return HStack(spacing: Ax.s2) {
            HStack(spacing: 3) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.down)
                Text(ByteFormat.size(totals.in))
                    .font(AxFont.supporting)
                    .monospacedDigit()
                    .foregroundStyle(Theme.textPrimary)
            }
            HStack(spacing: 3) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.up)
                Text(ByteFormat.size(totals.out))
                    .font(AxFont.supporting)
                    .monospacedDigit()
                    .foregroundStyle(Theme.textPrimary)
            }
            Spacer(minLength: 0)
            Text(router.trafficRange.rangeLabel)
                .font(AxFont.caption)
                .foregroundStyle(Theme.textTertiary)
        }
    }

    /// 桶时间戳 → 轴标签：日视图标时刻，周/月图标日期
    private func timeLabel(_ time: TimeInterval?) -> String {
        guard let time else { return "" }
        let date = Date(timeIntervalSince1970: time)
        let comps = Calendar.current.dateComponents([.month, .day, .hour, .minute], from: date)
        let month = comps.month ?? 0
        let day = comps.day ?? 0
        switch router.trafficRange {
        case .day:
            return String(format: "%02d:%02d", comps.hour ?? 0, comps.minute ?? 0)
        case .week, .month:
            return "\(month)/\(day)"
        case .live:
            return ""
        }
    }

    private var historyEmpty: some View {
        HStack(spacing: Ax.s2) {
            Image(systemName: "chart.bar")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
            Text(engine.historyAvailable
                 ? "该时间段没有流量记录 · 数据按 5 分钟桶持续累积"
                 : "历史库不可用，无法统计")
                .font(AxFont.supporting)
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 22)
    }

    /// 图表下沿的时间标注：起点居左、终点居右
    private func chartFooter(startLabel: String, endLabel: String) -> some View {
        HStack {
            Text(startLabel)
                .font(.system(size: 8))
                .monospacedDigit()
                .foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 0)
            Text(endLabel)
                .font(.system(size: 8))
                .monospacedDigit()
                .foregroundStyle(Theme.textTertiary)
        }
    }

    // MARK: - 应用列表

    private var appList: some View {
        Group {
            if router.trafficRange == .live {
                liveAppList
            } else {
                historyAppList
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: 实时档列表（引擎每秒刷新的速率排行）

    private var liveAppList: some View {
        Group {
            if engine.rows.isEmpty {
                emptyState
            } else {
                listCard {
                    ForEach(engine.rows) { row in
                        AppRowView(row: row, fraction: fraction(for: row))
                        if row.id != engine.rows.last?.id {
                            AxDivider(inset: Ax.s3 + 24)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func fraction(for row: AppTrafficRow) -> Double {
        guard engine.peakRowTotal > 0 else { return 0 }
        return row.total / engine.peakRowTotal
    }

    // MARK: 历史档列表（该时间段每应用的累计流量排行）

    private var historyAppList: some View {
        Group {
            if engine.historyTopApps.isEmpty {
                listCard {
                    HStack(spacing: Ax.s2) {
                        Image(systemName: "app.dashed")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textTertiary)
                        Text("该时间段没有应用流量记录")
                            .font(AxFont.supporting)
                            .foregroundStyle(Theme.textSecondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 30)
                }
            } else {
                listCard {
                    ForEach(engine.historyTopApps) { entry in
                        HistoryAppRow(entry: entry,
                                      peak: historyPeakTotal,
                                      showsShield: false)
                        if entry.id != engine.historyTopApps.last?.id {
                            AxDivider(inset: Ax.s3 + 24)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var historyPeakTotal: UInt64 {
        engine.historyTopApps.map(\.total).max() ?? 0
    }

    /// 列表卡片外壳：表头 + 内容 + 圆角容器。实时档与历史档共用一套外观。
    @ViewBuilder
    private func listCard(@ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: Ax.s2) {
                Text(router.trafficRange == .live ? "应用" : "应用 · \(router.trafficRange.rangeLabel)")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("上行").frame(width: 64, alignment: .trailing)
                Text("下行").frame(width: 64, alignment: .trailing)
            }
            .font(AxFont.caption)
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, Ax.s3)
            .padding(.vertical, 5)

            AxDivider()

            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    content()
                }
            }
            .scrollIndicators(.automatic)
            .clipShape(RoundedRectangle(cornerRadius: Ax.radiusContainer, style: .continuous))
        }
        .background(
            RoundedRectangle(cornerRadius: Ax.radiusContainer, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Ax.radiusContainer, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
        .shadow(color: Theme.cardShadow, radius: 4, x: 0, y: 2)
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private var emptyState: some View {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Ax.radiusContainer, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Ax.radiusContainer, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
    }
}

/// 历史档的应用行：图标 + 名称 + 占比条 + 该时间段内的累计上行/下行。
/// 与实时档的 `AppRowView` 同一外观语言（36pt 行高、两条右对齐数值列），
/// 但数值是 ByteFormat.size 总量而不是速率。
private struct HistoryAppRow: View {
    let entry: HistoryStore.AppEntry
    let peak: UInt64
    var showsShield: Bool

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

    /// app_key 是可执行文件路径（如 /Applications/Safari.app），直接问系统要图标；
    /// 拿不到就退回通用可执行文件图标。
    private var icon: NSImage {
        let image = NSWorkspace.shared.icon(forFile: entry.key)
        return image.size.width > 0 ? image : NSWorkspace.shared.icon(for: .unixExecutable)
    }
}

/// 流量速率双线图：下行（蓝，铺淡渐变）在上、上行（橙）在下，同一自动定标坐标。
/// 实时档 60 点、日 288 点、周 336 点、月 360 点 —— Canvas 逐点画线都不吃力。
/// Y 轴不画网格刻度线，只在右上角标出定标峰值；绝对量在汇总行里。
private struct RateLinesChart: View {
    let down: [Double]
    let up: [Double]

    static let chartHeight: CGFloat = 60
    private let scaleWidth: CGFloat = 54

    var body: some View {
        Canvas { context, size in
            let topInset: CGFloat = 8
            let plotWidth = max(size.width - scaleWidth, 1)
            let baselineY = size.height - 0.5
            let plotHeight = max(baselineY - topInset, 1)

            let peak = max(down.max() ?? 0, up.max() ?? 0, 1)
            func y(_ value: Double) -> CGFloat {
                let ratio = min(max(value / peak, 0), 1)
                return baselineY - CGFloat(ratio) * plotHeight
            }

            // 基线
            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: baselineY))
            baseline.addLine(to: CGPoint(x: plotWidth, y: baselineY))
            context.stroke(baseline, with: .color(Theme.textTertiary.opacity(0.30)), lineWidth: 0.5)

            // 定标峰值标注
            let peakText = context.resolve(
                Text(ByteFormat.rate(peak))
                    .font(.system(size: 7.5))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textTertiary)
            )
            context.draw(peakText, at: CGPoint(x: plotWidth + 4, y: topInset + 3), anchor: .leading)

            func line(_ values: [Double]) -> Path? {
                guard values.count >= 2 else { return nil }
                let stepX = plotWidth / CGFloat(max(values.count - 1, 1))
                var path = Path()
                for (index, value) in values.enumerated() {
                    let point = CGPoint(x: CGFloat(index) * stepX, y: y(value))
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                return path
            }

            // 只给下行铺一层很淡的渐变：两条都填色会互相盖住
            if let downLine = line(down) {
                var fill = downLine
                fill.addLine(to: CGPoint(x: plotWidth, y: size.height))
                fill.addLine(to: CGPoint(x: 0, y: size.height))
                fill.closeSubpath()
                context.fill(fill, with: .linearGradient(
                    Gradient(colors: [Theme.down.opacity(0.16), Theme.down.opacity(0.01)]),
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: 0, y: size.height)
                ))
                context.stroke(downLine, with: .color(Theme.down),
                               style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
            }
            if let upLine = line(up) {
                context.stroke(upLine, with: .color(Theme.up),
                               style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(height: Self.chartHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("流量速率曲线，下行蓝线，上行橙线")
    }
}
