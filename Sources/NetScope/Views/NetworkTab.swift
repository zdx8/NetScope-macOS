import SwiftUI

/// 「网络」主视图：紧凑双速率 KPI 条 + 交互式流量统计卡 + 应用流量排行列表。
struct NetworkTab: View {
    @ObservedObject var engine: MonitorEngine
    @ObservedObject var settings: Settings
    @ObservedObject var router: PanelRouter

    var body: some View {
        VStack(spacing: 10) {
            rateSummaryCard
            TrafficChartCard(engine: engine, router: router)
            TrafficAppList(engine: engine, router: router)
        }
        .padding(.horizontal, Ax.s4)
        .padding(.top, Ax.s3)
        .padding(.bottom, Ax.s2)
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear {
            if let granularity = router.trafficRange.granularity {
                engine.refreshHistory(range: granularity)
            }
        }
    }

    // MARK: - 顶部紧凑双速率 KPI 条（先上行后下行）

    private var rateSummaryCard: some View {
        AxCard(padding: Ax.s3, spacing: 0) {
            HStack(spacing: 0) {
                rateColumn(title: "上行",
                           symbol: "arrow.up",
                           color: Theme.up,
                           rate: ByteFormat.rate(engine.totalUp),
                           sessionTotal: ByteFormat.size(engine.sessionUp))

                Rectangle()
                    .fill(Theme.border)
                    .frame(width: 1, height: 36)
                    .padding(.horizontal, Ax.s3)

                rateColumn(title: "下行",
                           symbol: "arrow.down",
                           color: Theme.down,
                           rate: ByteFormat.rate(engine.totalDown),
                           sessionTotal: ByteFormat.size(engine.sessionDown))
            }
        }
    }

    private func rateColumn(title: String,
                            symbol: String,
                            color: Color,
                            rate: String,
                            sessionTotal: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(color)
                Text(title)
                    .font(AxFont.caption)
                    .foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 2)
                Text("本次 \(sessionTotal)")
                    .font(.system(size: 9.5).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }

            Text(rate)
                .font(AxFont.number(20))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) \(rate)，本次累计 \(sessionTotal)")
    }
}
