// 生成 NetScope 的 .iconset（不依赖任何外部图形工具）。
// 用法：swiftc -O -o /tmp/make-icon Scripts/make_icon.swift && /tmp/make-icon <输出目录>
import AppKit

/// 品牌色只在这里定义一处，界面侧 Theme.swift 用的是同一组分量。
let topColor = CGColor(red: 0.078, green: 0.137, blue: 0.322, alpha: 1)      // #142353
let bottomColor = CGColor(red: 0.176, green: 0.502, blue: 0.945, alpha: 1)   // #2D80F1

func render(pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    guard let graphics = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.current = graphics
    let context = graphics.cgContext
    let size = CGFloat(pixels)

    let inset = size * 0.052
    let body = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = size * 0.223
    context.addPath(CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.clip()

    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: [topColor, bottomColor] as CFArray,
                                 locations: [0, 1]) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: body.minX, y: body.maxY),
            end: CGPoint(x: body.maxX, y: body.minY),
            options: []
        )
    }

    // 底部一道柔和高光，避免纯渐变显得扁平
    if let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                             colors: [CGColor(red: 1, green: 1, blue: 1, alpha: 0.16),
                                      CGColor(red: 1, green: 1, blue: 1, alpha: 0)] as CFArray,
                             locations: [0, 1]) {
        context.drawRadialGradient(
            glow,
            startCenter: CGPoint(x: body.midX, y: body.maxY * 0.15), startRadius: 0,
            endCenter: CGPoint(x: body.midX, y: body.maxY * 0.15), endRadius: size * 0.7,
            options: []
        )
    }

    if let symbol = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: nil),
       let configured = symbol.withSymbolConfiguration(
           NSImage.SymbolConfiguration(pointSize: size * 0.40, weight: .bold)) {
        let symbolSize = configured.size
        let tinted = NSImage(size: symbolSize)
        tinted.lockFocus()
        configured.draw(in: NSRect(origin: .zero, size: symbolSize))
        NSColor.white.set()
        NSRect(origin: .zero, size: symbolSize).fill(using: .sourceAtop)
        tinted.unlockFocus()
        tinted.draw(in: NSRect(
            x: (size - symbolSize.width) / 2,
            y: (size - symbolSize.height) / 2,
            width: symbolSize.width,
            height: symbolSize.height
        ))
    }

    return rep.representation(using: .png, properties: [:])
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("用法：make_icon <输出目录>\n".utf8))
    exit(2)
}
let outputDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

// 尺寸与文件名的对应关系不能错，否则 iconutil 会报错或图标模糊
let variants: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (name, pixels) in variants {
    guard let data = render(pixels: pixels) else {
        FileHandle.standardError.write(Data("渲染 \(name) 失败\n".utf8))
        exit(1)
    }
    try data.write(to: outputDirectory.appendingPathComponent(name))
}

print("已生成 \(variants.count) 个尺寸到 \(outputDirectory.path)")
