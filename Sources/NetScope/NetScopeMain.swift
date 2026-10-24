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

        // 调试入口：`NetScope --show-panel` 启动后自动弹出面板，
        // 便于在无人值守环境截图核对真实 popover（材质、圆角、自适应高度）。
        if CommandLine.arguments.contains("--show-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                controller.presentPanelForCapture()
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
        print("本次累计下行: \(ByteFormat.size(engine.sessionDown))")
        print("曲线点数    : \(engine.history.points.count)")
        print("应用条目    : \(engine.rows.count)")
        for row in engine.rows.prefix(6) {
            let iconState = row.icon == nil ? "无图标" : "有图标"
            print("  · \(row.name)  ↓\(ByteFormat.rate(row.down))  ↑\(ByteFormat.rate(row.up))  [\(iconState)]")
        }

        engine.refreshHistory()
        print("历史库      : \(engine.historyAvailable ? "可用" : "不可用")")
        print("今日累计    : \(ByteFormat.size(engine.todayTotal))")
        print("近 7 天     : \(ByteFormat.size(engine.weekTotal))")
        if !engine.topAppsInHistory.isEmpty {
            let top = engine.topAppsInHistory.prefix(3)
                .map { "\($0.name) \(ByteFormat.size($0.total))" }
                .joined(separator: "、")
            print("今日 Top    : \(top)")
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

        // 可选：把面板离屏渲染成 PNG，用于人工核对排版（不依赖屏幕录制权限）
        if let index = arguments.firstIndex(of: "--render-panel"), index + 1 < arguments.count {
            let base = arguments[index + 1]
            for scheme in [ColorScheme.light, ColorScheme.dark] {
                let suffix = scheme == .light ? "light" : "dark"
                let path = base.replacingOccurrences(of: ".png", with: "-\(suffix).png")
                if renderPanel(engine: engine, settings: .shared, to: path, scheme: scheme) {
                    print("面板快照    : \(path)")
                } else {
                    print("面板快照    : \(path) 渲染失败")
                }
            }
        }

        engine.stop()
        exit(ok ? 0 : 1)
    }

    /// 把 PanelView 挂进一个永不显示的无边框窗口再渲染 —— 只建 NSHostingView
    /// 时部分容器量不到尺寸，布局不会完整解析。
    ///
    /// 必须显式指定 colorScheme 并自己铺底色：离屏窗口没有 popover 的材质背景，
    /// 若跟随系统外观（本机是深色），文字会是白色而背景是透明的，看起来像"什么都没画"。
    @MainActor
    private static func renderPanel(engine: MonitorEngine,
                                    settings: Settings,
                                    to path: String,
                                    scheme: ColorScheme) -> Bool {
        let backdrop = scheme == .dark
            ? Color(red: 0.129, green: 0.129, blue: 0.137)
            : Color(red: 0.980, green: 0.980, blue: 0.984)
        let content = PanelView(engine: engine, settings: settings)
            .background(backdrop)
            .environment(\.colorScheme, scheme)

        let host = NSHostingView(rootView: content)
        let fitting = host.fittingSize
        let size = CGSize(width: 348, height: max(fitting.height, 200))
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
}
