import AppKit

/// 菜单栏图标用的迷你趋势图。
///
/// 做成 template image（纯黑 + alpha）：系统会按深浅色自动反色，不需要自己判断外观。
/// 只画下线一条折线，不加填充 —— 18pt 高的空间里，填充会把形状糊成一团。
enum MenuBarSparkline {
    static func image(history: RateHistory,
                      size: NSSize = NSSize(width: 34, height: 18),
                      pointLimit: Int = 40) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            let color = NSColor.black
            let points = Array(history.points.suffix(pointLimit))

            // 数据不足时画一条扁基线，保证菜单栏里始终有个可见的图标
            guard points.count >= 2 else {
                let baseline = NSBezierPath()
                baseline.move(to: NSPoint(x: 1.5, y: 3))
                baseline.line(to: NSPoint(x: rect.width - 1.5, y: 3))
                baseline.lineWidth = 1.6
                baseline.lineCapStyle = .round
                color.withAlphaComponent(0.55).setStroke()
                baseline.stroke()
                return true
            }

            let inset: CGFloat = 1.5
            let usableWidth = rect.width - inset * 2
            let usableHeight = rect.height - inset * 2 - 1.5
            let peak = max(history.peak, 1024)

            func position(_ index: Int, _ value: Double) -> NSPoint {
                let ratio = min(max(value / peak, 0), 1)
                let x = inset + usableWidth * CGFloat(index) / CGFloat(points.count - 1)
                let y = inset + usableHeight * CGFloat(ratio)
                return NSPoint(x: x, y: y)
            }

            // 基线：让"没有流量"和"有一点点流量"在视觉上可区分
            let baseline = NSBezierPath()
            baseline.move(to: NSPoint(x: inset, y: inset))
            baseline.line(to: NSPoint(x: rect.width - inset, y: inset))
            baseline.lineWidth = 1
            color.withAlphaComponent(0.3).setStroke()
            baseline.stroke()

            let path = NSBezierPath()
            for (index, point) in points.enumerated() {
                let position = position(index, point.down)
                if index == 0 {
                    path.move(to: position)
                } else {
                    path.line(to: position)
                }
            }
            path.lineWidth = 1.3
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            color.setStroke()
            path.stroke()

            // 最新点加一个小圆点，读数时有个明确的"当前值"锚点
            if let last = points.last {
                let dot = position(points.count - 1, last.down)
                let radius: CGFloat = 1.4
                let circle = NSBezierPath(ovalIn: NSRect(
                    x: dot.x - radius, y: dot.y - radius,
                    width: radius * 2, height: radius * 2
                ))
                color.setFill()
                circle.fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "NetScope 流量趋势"
        return image
    }
}
