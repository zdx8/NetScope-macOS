import AppKit

/// 菜单栏槽位。合并成一项之后，`rawValue` 同时用作按钮 tag 与点击命中的标识。
enum MenuBarSlot: Int, CaseIterable {
    case cpu
    case memory
    case network

    var title: String {
        switch self {
        case .cpu: return "CPU 占用"
        case .memory: return "内存占用"
        case .network: return "网络流量"
        }
    }
}

/// 网络段的两种形态。定义在这里而不是直接引用 `Settings.NetworkBarStyle`，
/// 是为了让自检（只编译纯逻辑层）也能断言布局，不必把 ServiceManagement 拖进来。
enum NetworkGlyph {
    case rate
    case sparkline
}

/// 合并后的菜单栏徽标：`42% │ 79% │ ↑1.2M`，竖线分隔三段。
///
/// 为什么整块画成一张 NSImage：一个 `NSStatusItem` 只能有一个按钮，
/// 而需求是「点哪段弹哪段」+「用竖线分隔」。自己画才能同时拿到
/// ①精确的两行基线 ②每段的像素区间（点击命中用）。
///
/// 宽度固定策略：百分比列按 `100%` 的实测宽度、速率列按 `↑999K` 的实测宽度，
/// 数值在 9% / 42% / 100% 之间跳变时整块宽度不变，右侧图标不会被推着抖。
enum MenuBarBadge {
    struct Segment {
        let slot: MenuBarSlot
        /// 图像坐标系（原点左下），点击命中与 popover 锚点都按它换算
        let frame: NSRect
    }

    struct Rendered {
        let image: NSImage
        let segments: [Segment]
    }

    struct State {
        var cpu: Double?
        var memory: Double?
        var up: Double
        var down: Double
        var networkGlyph: NetworkGlyph = .rate
        /// 趋势形态用的历史（只有 `.sparkline` 读它）
        var sparkline: RateHistory?
        var visible: Set<MenuBarSlot> = Set(MenuBarSlot.allCases)
    }

    // MARK: - 度量

    // 1.3 反馈「菜单栏图标紧凑一些」：内边距、分隔带、图标各收 1–2pt，
    // 整块从 141pt 收到约 131pt。字号不动——再小就看不清了。
    private static let height: CGFloat = 22
    private static let horizontalPadding: CGFloat = 2
    private static let separatorGap: CGFloat = 5
    private static let iconSize: CGFloat = 11
    private static let iconGap: CGFloat = 2

    private static let percentFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold)
    private static let labelFont = NSFont.systemFont(ofSize: 7.5, weight: .medium)
    private static let rateFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)

    private static let percentWidth = ceil(("100%" as NSString)
        .size(withAttributes: [.font: percentFont]).width)
    private static let rateWidth = ceil(("↓999K" as NSString)
        .size(withAttributes: [.font: rateFont]).width)

    /// 每段的内容宽度（不含分隔线）
    private static func width(for slot: MenuBarSlot, state: State) -> CGFloat {
        switch slot {
        case .cpu, .memory:
            return percentWidth
        case .network:
            let content: CGFloat
            switch state.networkGlyph {
            case .rate: content = rateWidth
            case .sparkline: content = 30
            }
            return iconSize + iconGap + content
        }
    }

    // MARK: - 布局（纯计算，自检直接断言）

    static func layout(_ state: State) -> [Segment] {
        let order: [MenuBarSlot] = [.cpu, .memory, .network]
        let visible = order.filter { state.visible.contains($0) }
        var segments: [Segment] = []
        var x = horizontalPadding

        for (index, slot) in visible.enumerated() {
            if index > 0 {
                x += separatorGap + 1 + separatorGap
            }
            let w = width(for: slot, state: state)
            segments.append(Segment(slot: slot,
                                    frame: NSRect(x: x, y: 0, width: w, height: height)))
            x += w
        }
        return segments
    }

    static func imageWidth(_ state: State) -> CGFloat {
        guard let last = layout(state).last else { return 0 }
        return last.frame.maxX + horizontalPadding
    }

    /// 点击位置 → 槽位。段之间那 13pt 的分隔带归到**右边**那段，
    /// 这样「点在竖线上」也能打开一个面板，不会出现点了没反应的死区。
    static func slot(atX x: CGFloat, segments: [Segment]) -> MenuBarSlot? {
        guard !segments.isEmpty else { return nil }
        for segment in segments where x < segment.frame.maxX + separatorGap {
            return segment.slot
        }
        return segments.last?.slot
    }

    // MARK: - 绘制

    static func render(_ state: State) -> Rendered {
        let segments = layout(state)
        let width = imageWidth(state)
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .right
            paragraph.lineBreakMode = .byClipping

            func draw(_ text: String, font: NSFont, alpha: CGFloat,
                      in box: NSRect, lineHeight: CGFloat, bottomY: CGFloat) {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    // template image 只认 alpha：用「浅一点」区分主次，不能换颜色
                    .foregroundColor: NSColor.black.withAlphaComponent(alpha),
                    .paragraphStyle: paragraph
                ]
                (text as NSString).draw(in: NSRect(x: box.minX, y: bottomY,
                                                   width: box.width, height: lineHeight),
                                        withAttributes: attributes)
            }

            for (index, segment) in segments.enumerated() {
                if index > 0 {
                    let separatorX = segment.frame.minX - separatorGap - 0.5
                    NSColor.black.withAlphaComponent(0.22).setFill()
                    NSRect(x: separatorX, y: 4, width: 1, height: rect.height - 8).fill()
                }

                var contentX = segment.frame.minX
                var contentWidth = segment.frame.width

                if segment.slot == .network {
                    if let icon = NSImage(systemSymbolName: "network", accessibilityDescription: nil) {
                        let iconRect = NSRect(x: contentX,
                                              y: (rect.height - iconSize) / 2,
                                              width: iconSize, height: iconSize)
                        icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1)
                    }
                    contentX += iconSize + iconGap
                    contentWidth -= iconSize + iconGap
                }

                let box = NSRect(x: contentX, y: 0, width: contentWidth, height: rect.height)

                switch segment.slot {
                case .cpu, .memory:
                    let top = segment.slot == .cpu
                        ? PercentFormat.text(state.cpu)
                        : PercentFormat.text(state.memory)
                    let label = segment.slot == .cpu ? "CPU" : "MEM"
                    drawTwoLines(top: top, topFont: percentFont, topHeight: 12,
                                 bottom: label, bottomFont: labelFont, bottomHeight: 9,
                                 in: box, draw: draw)

                case .network:
                    switch state.networkGlyph {
                    case .rate:
                        drawTwoLines(top: "↑" + ByteFormat.compact(state.up),
                                     topFont: rateFont, topHeight: 11,
                                     bottom: "↓" + ByteFormat.compact(state.down),
                                     bottomFont: rateFont, bottomHeight: 11,
                                     in: box, draw: draw)
                    case .sparkline:
                        if let history = state.sparkline {
                            let spark = MenuBarSparkline.image(history: history,
                                                               size: NSSize(width: 30, height: 13),
                                                               pointLimit: 40)
                            spark.draw(in: NSRect(x: box.minX,
                                                  y: (rect.height - 13) / 2,
                                                  width: 30, height: 13),
                                       from: .zero, operation: .sourceOver, fraction: 1)
                        }
                    }
                }
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityText(state)
        return Rendered(image: image, segments: segments)
    }

    private static func drawTwoLines(
        top: String, topFont: NSFont, topHeight: CGFloat,
        bottom: String, bottomFont: NSFont, bottomHeight: CGFloat,
        in box: NSRect,
        draw: (String, NSFont, CGFloat, NSRect, CGFloat, CGFloat) -> Void
    ) {
        let blockHeight = topHeight + bottomHeight
        let bottomY = box.midY - blockHeight / 2
        draw(bottom, bottomFont, 0.8, box, bottomHeight, bottomY)
        draw(top, topFont, 1, box, topHeight, bottomY + bottomHeight)
    }

    static func accessibilityText(_ state: State) -> String {
        var parts: [String] = []
        if state.visible.contains(.cpu) { parts.append("CPU \(PercentFormat.text(state.cpu))") }
        if state.visible.contains(.memory) { parts.append("内存 \(PercentFormat.text(state.memory))") }
        if state.visible.contains(.network) {
            parts.append("上行 \(ByteFormat.rate(state.up))，下行 \(ByteFormat.rate(state.down))")
        }
        return parts.joined(separator: "；")
    }
}
