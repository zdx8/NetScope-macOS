import SwiftUI

/// 0–100% 固定刻度的负载曲线。面板里的迷你块（18pt 高）与独立详情面板（约 96pt）共用同一实现。
///
/// 为什么用固定刻度而不是按峰值归一化：5% 的 CPU 画满整高会让人误判机器状态；
/// 固定刻度下「线在底部」本身就是「机器很闲」的信息。
struct LoadChart: View {
    let history: LoadHistory
    let accent: Color
    var height: CGFloat = 18
    /// 右侧是否标出 100% / 50% / 0 的刻度文字。迷你块宽度不足，默认关闭。
    var showsScale: Bool = false
    var lineWidth: CGFloat = 1.1

    /// 刻度文字预留的宽度（含与绘图区的间距）
    private let scaleWidth: CGFloat = 27

    var body: some View {
        Canvas { context, size in
            // 有刻度时顶部要压低一点，否则「100%」这几个字会被画布上沿裁掉一半
            let topInset: CGFloat = showsScale ? 7 : 0
            let plotWidth = max(size.width - (showsScale ? scaleWidth : 0), 1)
            let baselineY = size.height - 0.5
            let plotHeight = max(baselineY - topInset, 1)

            func y(for value: Double) -> CGFloat {
                let ratio = min(max(value, 0), 100) / 100
                return baselineY - CGFloat(ratio) * plotHeight
            }

            // 虚线而不是实线：启动初期只有几个样本时，全宽实线容易被看成「一条平坦的数据线」
            func gridLine(_ value: Double, opacity: Double) {
                var path = Path()
                let lineY = y(for: value)
                path.move(to: CGPoint(x: 0, y: lineY))
                path.addLine(to: CGPoint(x: plotWidth, y: lineY))
                context.stroke(path, with: .color(Theme.textTertiary.opacity(opacity)),
                               style: StrokeStyle(lineWidth: 0.5, dash: [1.5, 2.5]))
            }

            gridLine(0, opacity: 0.30)
            // 50% 参考线：固定刻度下没有标尺就看不出「这条低线其实只占四分之一」
            gridLine(50, opacity: 0.14)
            if showsScale { gridLine(100, opacity: 0.14) }

            if showsScale {
                func label(_ text: String, at yPosition: CGFloat) {
                    let resolved = context.resolve(
                        Text(text)
                            .font(.system(size: 7.5))
                            .foregroundStyle(Theme.textTertiary)
                    )
                    context.draw(resolved,
                                 at: CGPoint(x: plotWidth + 5, y: yPosition),
                                 anchor: .leading)
                }
                label("100%", at: topInset + 1)
                label("50%", at: (topInset + baselineY) / 2)
                label("0", at: baselineY - 5)
            }

            let points = history.points
            guard points.count >= 2, plotWidth > 1 else { return }

            let slots = max(history.capacity, points.count)
            let stepX = plotWidth / CGFloat(max(slots - 1, 1))

            var line = Path()
            for (index, value) in points.enumerated() {
                let point = CGPoint(x: CGFloat(index) * stepX, y: y(for: value))
                if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
            }

            var fill = line
            fill.addLine(to: CGPoint(x: CGFloat(points.count - 1) * stepX, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()
            context.fill(fill, with: .linearGradient(
                Gradient(colors: [accent.opacity(0.20), accent.opacity(0.01)]),
                startPoint: CGPoint(x: 0, y: 0),
                endPoint: CGPoint(x: 0, y: size.height)
            ))
            context.stroke(line, with: .color(accent),
                           style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
        .frame(height: height)
    }
}
