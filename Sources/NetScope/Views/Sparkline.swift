import SwiftUI

/// 近 60 秒的双向速率曲线。下行实线 + 渐变填充，上行虚线。
struct Sparkline: View {
    let history: RateHistory
    var height: CGFloat = 54

    var body: some View {
        Canvas { context, size in
            let points = history.points
            guard points.count >= 2, size.width > 1 else { return }

            let slots = max(history.capacity, points.count)
            let stepX = size.width / CGFloat(max(slots - 1, 1))
            // 从左往右生长：刚启动时能立刻看到曲线在铺开，而不是右侧一截孤立的尖峰。
            // 满 capacity 个样本后自然铺满整宽，最新点始终在最右侧。
            let startX: CGFloat = 0
            let peak = max(history.peak, 1024)
            let topInset: CGFloat = 3
            let usableHeight = max(size.height - topInset, 1)

            func position(_ index: Int, _ value: Double) -> CGPoint {
                let clamped = min(max(value / peak, 0), 1)
                return CGPoint(
                    x: startX + CGFloat(index) * stepX,
                    y: size.height - CGFloat(clamped) * usableHeight
                )
            }

            func line(_ values: [Double]) -> Path {
                var path = Path()
                for (index, value) in values.enumerated() {
                    let point = position(index, value)
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                return path
            }

            let downLine = line(points.map(\.down))
            let upLine = line(points.map(\.up))

            var fill = downLine
            fill.addLine(to: CGPoint(x: startX + CGFloat(points.count - 1) * stepX, y: size.height))
            fill.addLine(to: CGPoint(x: startX, y: size.height))
            fill.closeSubpath()
            context.fill(fill, with: .linearGradient(
                Gradient(colors: [Theme.down.opacity(0.26), Theme.down.opacity(0.01)]),
                startPoint: CGPoint(x: 0, y: 0),
                endPoint: CGPoint(x: 0, y: size.height)
            ))

            context.stroke(downLine, with: .color(Theme.down),
                           style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            context.stroke(upLine, with: .color(Theme.up),
                           style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round,
                                              dash: [3.5, 2.5]))
        }
        .frame(height: height)
        .accessibilityLabel("近 \(history.capacity) 秒速率曲线")
    }
}
