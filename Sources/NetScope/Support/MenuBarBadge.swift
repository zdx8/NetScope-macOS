import AppKit

/// 菜单栏内容：网络图标 + 双行数值（上行在上、下行在下）。
///
/// 为什么整块画成一张 NSImage，而不是 `image` + `attributedTitle`：
/// 菜单栏按钮默认单行排版，塞两行文本会被压扁或截断；自己画才能精确控制图标位置、
/// 两行基线，以及让数字右对齐成一列。
///
/// 另外固定了文字区的最小宽度（约 `999K` 的宽度）：速率在 1.2K / 12K / 999K 之间跳变时，
/// 若宽度跟着变，菜单栏右侧的所有图标都会左右抖动。
enum MenuBarBadge {
    static func image(up: Double, down: Double) -> NSImage {
        let iconSize: CGFloat = 14
        let gap: CGFloat = 3.5
        let fontSize: CGFloat = 8.5
        let lineHeight: CGFloat = 9.5
        let minTextWidth: CGFloat = 27

        let upText = "↑" + ByteFormat.compact(up)
        let downText = "↓" + ByteFormat.compact(down)

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        paragraph.lineBreakMode = .byClipping

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraph
        ]

        let measured = max(
            ceil((upText as NSString).size(withAttributes: attributes).width),
            ceil((downText as NSString).size(withAttributes: attributes).width)
        )
        let textWidth = max(measured, minTextWidth)
        let size = NSSize(width: iconSize + gap + textWidth + 1, height: 22)

        let image = NSImage(size: size, flipped: false) { rect in
            if let icon = NSImage(systemSymbolName: "network", accessibilityDescription: nil) {
                let iconRect = NSRect(x: 0,
                                      y: (rect.height - iconSize) / 2,
                                      width: iconSize,
                                      height: iconSize)
                icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1.0)
            }

            let textX = iconSize + gap
            let centerY = rect.height / 2
            // 上行贴在中线之上，下行贴在中线之下
            let upRect = NSRect(x: textX, y: centerY + 0.5, width: textWidth, height: lineHeight)
            let downRect = NSRect(x: textX, y: centerY - lineHeight + 0.5,
                                  width: textWidth, height: lineHeight)
            (upText as NSString).draw(in: upRect, withAttributes: attributes)
            (downText as NSString).draw(in: downRect, withAttributes: attributes)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "上行 \(ByteFormat.rate(up))，下行 \(ByteFormat.rate(down))"
        return image
    }
}
