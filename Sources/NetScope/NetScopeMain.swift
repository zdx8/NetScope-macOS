import AppKit
import SwiftUI

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev"
    }
}

/// 未捕获的 Objective-C 异常会打在这里。系统级 DiagnosticReports 目录在本机不存在，
/// 没有这份日志就只能靠猜。
private func installCrashLogger() {
    NSSetUncaughtExceptionHandler { exception in
        let text = """
        [NetScope 崩溃] \(Date())
        name   : \(exception.name.rawValue)
        reason : \(exception.reason ?? "-")
        stack  :
        \(exception.callStackSymbols.joined(separator: "\n"))
        """
        let path = NSHomeDirectory() + "/Library/Logs/NetScope-crash.log"
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

@main
struct NetScopeMain {
    private static var retainedDelegate: AppDelegate?

    static func main() {
        let arguments = CommandLine.arguments

        if arguments.contains("--version") {
            print("NetScope \(AppInfo.version) (\(AppInfo.build))")
            exit(0)
        }

        if arguments.contains("--headless") {
            // main 一定运行在主线程，可以直接认领主 actor 隔离
            MainActor.assumeIsolated {
                HeadlessRunner.run(arguments: arguments)
            }
        }

        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        installCrashLogger()

        // 单实例：双击两次不应该出现两个菜单栏图标、两份 nettop
        let bundleID = Bundle.main.bundleIdentifier ?? "com.zdx8.netscope"
        let myPID = ProcessInfo.processInfo.processIdentifier
        let siblings = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != myPID }
        if !siblings.isEmpty {
            siblings.first?.activate()
            exit(0)
        }

        // 清理上一次异常退出留下的孤儿 nettop
        let reaped = OrphanReaper.reap()
        if !reaped.isEmpty {
            NSLog("NetScope: 已清理 \(reaped.count) 个遗留 nettop 进程 \(reaped)")
        }

        let delegate = AppDelegate()
        application.delegate = delegate
        retainedDelegate = delegate
        application.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusItemController?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = StatusItemController()
        self.controller = controller
        installSignalHandlers()

        // 调试入口：`--show-panel` / `--show-cpu` / `--show-memory` 启动后自动弹出对应面板，
        // 便于在无人值守环境截图核对真实 popover（材质、圆角、自适应高度）。
        if let slot = Self.captureSlot(from: CommandLine.arguments) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                controller.presentPanelForCapture(slot: slot)
            }
        }

        // 调试入口：打印三项菜单栏徽标的实际屏幕坐标后退出。
        // 用来判断「建了三个却只看到两个」到底是代码没建，还是菜单栏没地方了。
        if CommandLine.arguments.contains("--dump-menu") {
            setvbuf(stdout, nil, _IONBF, 0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                controller.dumpMenuBarGeometry()
                print("MENUBAR_DUMP_DONE")
                exit(0)
            }
        }

        // 回归测试入口：自动走一遍「刷新间隔」切换序列。
        // 这个操作曾在 Picker 回调里二次发送 objectWillChange 导致闪退，留个可复现的检查点。
        if CommandLine.arguments.contains("--test-interval") {
            setvbuf(stdout, nil, _IONBF, 0)
            let values = [2, 3, 5, 1]
            for (index, value) in values.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4 + Double(index) * 2.5) {
                    Settings.shared.sampleInterval = value
                    print("interval -> \(value)s  nettop=\(ProcessInfo.processInfo.environment["_"] ?? "?")")
                }
            }
            let finish = 4 + Double(values.count) * 2.5 + 3
            DispatchQueue.main.asyncAfter(deadline: .now() + finish) {
                print("TEST_INTERVAL_DONE alive=\(NSApplication.shared.isRunning)")
                exit(0)
            }
        }
    }

    /// 正常退出路径（菜单「退出」、Cmd+Q、系统注销）走这里。
    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutdown()
    }

    /// `pkill` / `kill` 发的是 SIGTERM，默认行为是直接终止进程、不执行任何清理。
    /// 拦截后显式清理并退出：不要依赖 `NSApp.terminate(nil)` 再回调
    /// `applicationWillTerminate` —— 在 accessory 应用里这条链路实测不可靠，
    /// 结果就是 nettop 变成孤儿进程继续每秒采样。
    private func installSignalHandlers() {
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    self?.controller?.shutdown()
                    exit(0)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// 三个截图入口共用一个延迟弹出逻辑，避免复制三份 DispatchQueue。
    private static func captureSlot(from arguments: [String]) -> MenuBarSlot? {
        if arguments.contains("--show-cpu") { return .cpu }
        if arguments.contains("--show-memory") { return .memory }
        if arguments.contains("--show-panel") { return .network }
        return nil
    }
}

/// 无界面自检：让**打包后的真实二进制**在不建窗口的情况下跑一轮完整采样，
/// 输出可被脚本断言的事实（样本数、进程数、Top 应用）。
enum HeadlessRunner {
    @MainActor
    static func run(arguments: [String]) -> Never {
        setvbuf(stdout, nil, _IONBF, 0)
        _ = NSApplication.shared

        print("NetScope 无界面自检 \(AppInfo.version) (\(AppInfo.build))")

        // `--interval N` 覆盖采样间隔，用来验证「改间隔真的重建了 nettop」：
        // 5 秒间隔下等 3 个样本要 15 秒左右，1 秒间隔下 3 秒就够 —— 时间差本身就是断言。
        var requestedInterval: Int?
        if let index = arguments.firstIndex(of: "--interval"),
           index + 1 < arguments.count,
           let value = Int(arguments[index + 1]) {
            let clamped = min(max(value, 1), 5)
            requestedInterval = clamped
            Settings.shared.sampleInterval = clamped
            print("采样间隔    : \(clamped)s（由 --interval 指定）")
        }

        let engine = MonitorEngine(requestNotificationPermission: false)
        engine.start()

        let targetSamples = requestedInterval == nil ? 8 : 3
        let sampleTimeout: TimeInterval = requestedInterval == nil ? 22 : 26
        let reached = engine.waitForSamples(targetSamples, timeout: sampleTimeout)
        print("样本数      : \(engine.sampleCount)")
        print("进程数      : \(engine.processCount)")
        print("状态        : \(engine.status.label)")
        print("隧道状态    : \(engine.isTunnelActive ? engine.tunnelNames.joined(separator: ", ") : "无")")
        print("总量口径    : \(engine.isUsingPhysicalTotal ? "物理网卡" : "全接口（回退）")")
        print("下行        : \(ByteFormat.rate(engine.totalDown))")
        print("上行        : \(ByteFormat.rate(engine.totalUp))")
        print("CPU 占用    : \(String(format: "%.1f", engine.systemLoad.cpuPercent))%（\(engine.systemLoad.sampleCount) 次采样）")
        if let memory = engine.systemLoad.memory {
            print("内存占用    : \(String(format: "%.1f", memory.percent))%  "
                  + "\(ByteFormat.size(memory.used)) / \(ByteFormat.size(memory.total))"
                  + "（压缩 \(ByteFormat.size(memory.compressed))）")
        } else {
            print("内存占用    : 读取失败")
        }
        print("本次累计下行: \(ByteFormat.size(engine.sessionDown))")
        print("曲线点数    : \(engine.history.points.count)")
        print("应用条目    : \(engine.rows.count)")
        print("进程负载    : \(engine.systemLoad.processRows.count) 个应用（Top: "
              + (engine.systemLoad.processRows.sorted { $0.cpu > $1.cpu }.first.map {
                  "\($0.name) \(PercentFormat.process($0.cpu))"
              } ?? "无") + "）")
        for row in engine.rows.prefix(6) {
            let iconState = row.icon == nil ? "无图标" : "有图标"
            print("  · \(row.name)  ↓\(ByteFormat.rate(row.down))  ↑\(ByteFormat.rate(row.up))  [\(iconState)]")
        }

        engine.refreshHistory(range: .fiveMinutes)
        print("历史库      : \(engine.historyAvailable ? "可用" : "不可用")")
        let dayTotal = engine.historySeries.reduce(UInt64(0)) { $0 + $1.total }
        print("近 24 小时  : \(ByteFormat.size(dayTotal))")
        if !engine.historyTopApps.isEmpty {
            let top = engine.historyTopApps.prefix(3)
                .map { "\($0.name) \(ByteFormat.size($0.total))" }
                .joined(separator: "、")
            print("24h Top     : \(top)")
        }

        let ok = reached
            && engine.sampleCount >= 3
            && engine.processCount > 0
            && engine.history.points.count >= 3
        print(ok ? "结果        : 通过" : "结果        : 失败")

        // 可选：注入合成数据后离屏渲染，用于验收「曲线铺满 + 列表满档」这类
        // 只有真实运行一分钟后才会出现的布局
        if arguments.contains("--demo") {
            engine.loadDemoData(tunnelActive: TunnelDetector.hasActiveTunnel())
        }

        // 可选：把面板离屏渲染成 PNG，用于人工核对排版与官网截图（不依赖屏幕录制权限）。
        // `--panel-mode settings` 决定面板落点，默认系统功能页；
        // `--range day|week|month` 决定流量统计档位（默认实时），demo 模式下历史数据按档位现合成。
        if let index = arguments.firstIndex(of: "--render-panel"), index + 1 < arguments.count {
            let base = arguments[index + 1]
            var showSettings = false
            if let modeIndex = arguments.firstIndex(of: "--panel-mode"), modeIndex + 1 < arguments.count {
                if arguments[modeIndex + 1] == "settings" { showSettings = true }
            }
            var range: TrafficRange = .live
            if let rangeIndex = arguments.firstIndex(of: "--range"), rangeIndex + 1 < arguments.count {
                switch arguments[rangeIndex + 1] {
                case "day": range = .day
                case "week": range = .week
                case "month": range = .month
                default: break
                }
            }
            for scheme in [ColorScheme.light, ColorScheme.dark] {
                let suffix = scheme == .light ? "light" : "dark"
                let path = base.replacingOccurrences(of: ".png", with: "-\(suffix).png")
                if renderPanel(engine: engine, settings: .shared, to: path, scheme: scheme,
                               showSettings: showSettings, range: range) {
                    print("面板快照    : \(path)")
                } else {
                    print("面板快照    : \(path) 渲染失败")
                }
            }
        }

        // 可选：CPU / 内存详情面板（菜单栏两项各自的弹窗），同样出浅色 + 深色两张
        if let index = arguments.firstIndex(of: "--render-load"), index + 1 < arguments.count {
            let base = arguments[index + 1]
            for kind in [ProcessMetric.cpu, .memory] {
                let name = kind == .cpu ? "cpu" : "memory"
                for scheme in [ColorScheme.light, ColorScheme.dark] {
                    let suffix = scheme == .light ? "light" : "dark"
                    let path = base.replacingOccurrences(of: ".png", with: "-\(name)-\(suffix).png")
                    if renderLoadPanel(engine: engine, kind: kind, to: path, scheme: scheme) {
                        print("负载快照    : \(path)")
                    } else {
                        print("负载快照    : \(path) 渲染失败")
                    }
                }
            }
        }

        // 可选：把三个菜单栏徽标合成一张对照图。
        // 菜单栏截图需要「屏幕录制」权限，无人值守环境拿不到；这里直接画一份等价物，
        // 用来核对数值对齐、三项宽度、深浅色反色是否正常。
        if let index = arguments.firstIndex(of: "--render-badges"), index + 1 < arguments.count {
            let base = arguments[index + 1]
            if renderBadgeStrip(engine: engine, to: base) {
                print("徽标快照    : \(base)")
            } else {
                print("徽标快照    : \(base) 渲染失败")
            }
        }

        engine.stop()
        exit(ok ? 0 : 1)
    }

    /// 把面板根视图挂进一个永不显示的无边框窗口再渲染 —— 只建 NSHostingView
    /// 时部分容器量不到尺寸，布局不会完整解析。
    ///
    /// 必须显式指定 colorScheme 并自己铺底色：离屏窗口没有 popover 的材质背景，
    /// 若跟随系统外观（本机是深色），文字会是白色而背景是透明的，看起来像"什么都没画"。
    @MainActor
    private static func renderPanel(engine: MonitorEngine,
                                    settings: Settings,
                                    to path: String,
                                    scheme: ColorScheme,
                                    showSettings: Bool = false,
                                    range: TrafficRange = .live) -> Bool {
        let router = PanelRouter()
        router.tab = .system
        router.trafficRange = range
        if let granularity = range.granularity {
            // demo 模式下按档位现合成历史；真实模式下查库
            engine.refreshHistory(range: granularity)
        }
        let content = DashboardView(engine: engine, settings: settings, router: router,
                                    showSettingsInitially: showSettings)
            .environment(\.colorScheme, scheme)
        return rasterize(content, width: Ax.panelWidth, to: path)
    }

    @MainActor
    private static func renderLoadPanel(engine: MonitorEngine,
                                        kind: ProcessMetric,
                                        to path: String,
                                        scheme: ColorScheme) -> Bool {
        let router = PanelRouter()
        router.tab = .cleanup
        router.sort = kind
        let content = DashboardView(engine: engine, settings: .shared, router: router)
            .environment(\.colorScheme, scheme)
        return rasterize(content, width: Ax.panelWidth, to: path)
    }

    private static func backdrop(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.106, green: 0.106, blue: 0.106)
            : Color(red: 0.945, green: 0.945, blue: 0.945)
    }

    @MainActor
    private static func rasterize<V: View>(_ content: V, width: CGFloat, to path: String) -> Bool {
        let host = NSHostingView(rootView: content)
        let fitting = host.fittingSize
        let size = CGSize(width: width, height: max(fitting.height, 120))
        host.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }

    // MARK: - 徽标对照图

    /// 按菜单栏真实形态合成浅色、深色两张对照图。
    ///
    /// 合并成一项之后只有一块徽标：`42% │ 79% │ ↑1.2M`。
    /// 这里用固定的演示数值，避免把本机真实占用带进官网截图。
    @MainActor
    private static func renderBadgeStrip(engine: MonitorEngine, to base: String) -> Bool {
        let state = MenuBarBadge.State(
            cpu: 42,
            memory: 79,
            up: 1_240_000,
            down: 8_420_000,
            networkGlyph: .rate,
            sparkline: engine.history
        )
        let rendered = MenuBarBadge.render(state)
        print("徽标宽度    : \(Int(rendered.image.size.width))pt / \(rendered.segments.count) 段")

        var ok = true
        for scheme in [ColorScheme.light, ColorScheme.dark] {
            let suffix = scheme == .light ? "light" : "dark"
            let path = base.replacingOccurrences(of: ".png", with: "-\(suffix).png")
            let dark = scheme == .dark
            guard let rep = badgeCanvas(badges: [rendered.image],
                                        tint: dark ? .white : .black,
                                        background: dark
                                            ? NSColor(red: 0.157, green: 0.157, blue: 0.169, alpha: 1)
                                            : NSColor(red: 0.961, green: 0.961, blue: 0.973, alpha: 1)),
                  let data = rep.representation(using: .png, properties: [:]) else {
                ok = false
                continue
            }
            if (try? data.write(to: URL(fileURLWithPath: path))) == nil { ok = false }
        }
        return ok
    }

    /// 以 2× 像素密度合成「菜单栏条带」。
    ///
    /// 之前用 `NSImage(size:flipped:)` 画，落地是 1× 位图，放到官网上糊成一团。
    /// 这里显式建 bitmap rep 并把 `size` 设成点尺寸，绘制仍按点坐标，
    /// 但输出是 2× —— 和面板截图（720×1040）同一密度。
    private static func badgeCanvas(badges: [NSImage], tint: NSColor, background: NSColor) -> NSBitmapImageRep? {
        let scale: CGFloat = 2
        let gap: CGFloat = 10
        let padding: CGFloat = 10
        let height: CGFloat = 26
        let width = badges.reduce(padding * 2) { $0 + $1.size.width }
            + gap * CGFloat(max(badges.count - 1, 0))

        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(width * scale),
                                         pixelsHigh: Int(height * scale),
                                         bitsPerSample: 8,
                                         samplesPerPixel: 4,
                                         hasAlpha: true,
                                         isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0,
                                         bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = NSSize(width: width, height: height)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        // bitmap rep 的绘图坐标系是**像素**，不是点：不缩放的话 2× 画布上只会画出半尺寸内容
        context.cgContext.scaleBy(x: scale, y: scale)
        background.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        var x = padding
        for badge in badges {
            let rect = NSRect(x: x,
                              y: (height - badge.size.height) / 2,
                              width: badge.size.width,
                              height: badge.size.height)
            // template image 在真实菜单栏里由系统按外观反色；离屏合成时手动染一层
            tinted(badge, tint).draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            x += badge.size.width + gap
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// 把 template image 染成指定颜色，按 2× 像素密度输出。
    /// 不用 `lockFocus`：它跟随主屏 backing scale，命令行/离屏环境下可能拿到 1×。
    private static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        let scale: CGFloat = 2
        let width = image.size.width
        let height = image.size.height
        guard width > 0, height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(width * scale),
                                         pixelsHigh: Int(height * scale),
                                         bitsPerSample: 8,
                                         samplesPerPixel: 4,
                                         hasAlpha: true,
                                         isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0,
                                         bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return image }
        rep.size = NSSize(width: width, height: height)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: scale, y: scale)
        image.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        // 只染已有像素：目标初始透明，sourceAtop 不会把空白区域涂成实心块
        color.setFill()
        NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
        NSGraphicsContext.restoreGraphicsState()

        let result = NSImage(size: image.size)
        result.addRepresentation(rep)
        return result
    }
}
