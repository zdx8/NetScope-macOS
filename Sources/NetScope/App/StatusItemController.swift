import AppKit
import SwiftUI
import Combine
import QuartzCore

/// 菜单栏**单项**控制器：一块徽标里画三段（CPU ｜ 内存 ｜ 网络），
/// 点哪一段就弹哪一段的详情。
///
/// 1.1.5 曾把三项拆成三个 `NSStatusItem`，实测撞上两个硬限制：
/// 1. 三项共约 159pt，而本机菜单栏右侧可用区只有 790pt 且已被占满，
///    macOS 会静默地把放不下的项藏到刘海下面（不报错、不提示）；
/// 2. 隐藏的 statusItem 仍参与布局，把可见项一起挤走。
///
/// 合并成一项后宽度降到约 130pt，同时保留「点哪段看哪段」：
/// 命中靠图像内的像素区间，popover 锚点用该段的矩形，箭头正好指在被点的那段下面。
@MainActor
final class StatusItemController: NSObject {
    private let item: NSStatusItem
    private var popover: NSPopover?
    private var currentSlot: MenuBarSlot?
    private let router = PanelRouter()
    private var segments: [MenuBarBadge.Segment] = []
    /// 上一次点击的时间，用来抑制同一次点击的重复 action
    private var lastClickAt: CFTimeInterval = 0
    /// 面板「刚被系统自动收起」的时刻。
    /// `.transient` 的 popover 在鼠标按下时就先按「点到面板外」收起来，
    /// 而状态项的动作回调晚一步才到，此时 `isShown` 已是 false；
    /// 只凭 `isShown` 判断会把这次点击当成「打开」，于是再点徽标永远关不掉。
    private var lastAutoCloseAt: CFTimeInterval = 0
    /// 我们自己主动调 `performClose` 时置位，避免那次收尾被误记成「用户点的收起」
    private var suppressCloseTracking = false
    /// 鼠标**按下那一刻**、且确认落在徽标内的位置。
    /// 状态项的 action 会被重复派发，其中一次是「收起面板的那一下」被重新投递，
    /// 它带的坐标按另一个窗口原点算，能离谱到 buttonX=-80（实测）。
    /// 所以位置在按下当刻记录并立刻用徽标矩形校验，不合法就整个点击作废。
    private var pressLocation: NSPoint?
    private var pressAt: CFTimeInterval = 0
    private var mouseMonitor: Any?
    private var lastTraceRect = ""
    /// 点击排障日志（`NETSCOPE_TRACE_CLICKS=1` 时打开）：stderr 不缓冲，重定向也能实时看到
    private static let traceClicks = ProcessInfo.processInfo.environment["NETSCOPE_TRACE_CLICKS"] == "1"

    private func trace(_ line: String) {
        guard Self.traceClicks else { return }
        FileHandle.standardError.write(Data(line.utf8))
    }

    private let engine = MonitorEngine()
    private let settings = Settings.shared
    private var cancellables: Set<AnyCancellable> = []

    override init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureItem()
        installPressMonitor()
        bindUpdates()
        engine.start()
    }

    /// 供无界面自检使用
    var monitorEngine: MonitorEngine { engine }

    // MARK: - 装配

    private func configureItem() {
        guard let button = item.button else { return }
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.target = self
        button.action = #selector(handleClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateBadge()
    }

    /// 记下「按下」那一刻的光标位置。
    ///
    /// 状态项的 action 走的是 mouseUp 派发，实测还会被系统延后（面板动画、
    /// 菜单跟踪期），等它执行时 `NSEvent.mouseLocation` 早已不是按下的位置。
    /// 监听器在 mouseDown 当刻读取，拿到的才是用户真正点的那个点。
    private func installPressMonitor() {
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] event in
            guard let self else { return event }
            let now = CACurrentMediaTime()
            self.pressAt = now
            // 菜单栏的 action 会被重复派发，其中一次来自「收起面板的那一下」被重新投递，
            // 它带的坐标是按另一个窗口原点算的，能离谱到 buttonX=-80。
            // 所以按下点必须用徽标矩形校验：不在徽标内就当没按过。
            self.pressLocation = self.badgeScreenRect().flatMap { rect -> NSPoint? in
                let point = NSEvent.mouseLocation
                return rect.insetBy(dx: -2, dy: -2).contains(point) ? point : nil
            }
            self.trace("DOWN t=\(String(format: "%.3f", now)) ev=\(String(format: "%.3f", event.timestamp)) "
                       + "mouse=\(NSEvent.mouseLocation) inside=\(self.pressLocation != nil) "
                       + "type=\(event.type.rawValue)\n")
            return event
        }
    }

    /// 徽标按钮当前占据的屏幕矩形（原点左下）
    private func badgeScreenRect() -> NSRect? {
        guard let button = item.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    /// 只有一个 popover：菜单栏三段现在指向两页内容，由 `router` 决定显示哪一页。
    /// 单一 popover 还顺带解决了「三个面板各自持有 SwiftUI 树」的内存浪费。
    private func panelPopover() -> NSPopover {
        if let existing = popover { return existing }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentSize = NSSize(width: Ax.panelWidth, height: Ax.panelHeight)

        let root = DashboardView(engine: engine, settings: settings, router: router)
        let host = NSHostingController(rootView: root)
        // 面板是固定尺寸（需求：详情页高度固定、列表内部滚动），
        // 关掉自动尺寸避免 SwiftUI 把 popover 拉成内容高度。
        host.sizingOptions = []
        // 主题：在宿主视图上设 NSAppearance。Theme 的语义色是 NSColor 动态色
        // （按 effectiveAppearance 解析），这里设了 SwiftUI 的 colorScheme
        // 环境也会跟着走，面板内外一起切；跟随系统时保持 nil。
        host.view.appearance = settings.appearanceTheme.nsAppearance
        popover.contentViewController = host
        self.popover = popover
        return popover
    }

    private func bindUpdates() {
        // 网络与系统负载两条通道各自触发重绘；合并后仍然只有一个按钮要刷
        let triggers: [AnyPublisher<Void, Never>] = [
            engine.$history.map { _ in () }.eraseToAnyPublisher(),
            engine.$totalDown.map { _ in () }.eraseToAnyPublisher(),
            engine.$totalUp.map { _ in () }.eraseToAnyPublisher(),
            engine.$status.map { _ in () }.eraseToAnyPublisher(),
            engine.systemLoad.$cpuPercent.map { _ in () }.eraseToAnyPublisher(),
            engine.systemLoad.$memory.map { _ in () }.eraseToAnyPublisher(),
            engine.systemLoad.$processRows.map { _ in () }.eraseToAnyPublisher(),
            settings.$networkBarStyle.map { _ in () }.eraseToAnyPublisher(),
            settings.$menuBarShowsCPU.map { _ in () }.eraseToAnyPublisher(),
            settings.$menuBarShowsMemory.map { _ in () }.eraseToAnyPublisher(),
            settings.$menuBarShowsNetwork.map { _ in () }.eraseToAnyPublisher()
        ]
        Publishers.MergeMany(triggers)
            .sink { [weak self] _ in
                Task { @MainActor in self?.updateBadge() }
            }
            .store(in: &cancellables)

        // 主题切换：popover 惰性创建，已存在时直接换宿主视图外观即可实时生效
        settings.$appearanceTheme
            .sink { [weak self] theme in
                Task { @MainActor in
                    self?.popover?.contentViewController?.view.appearance = theme.nsAppearance
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - 交互

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        // 一次物理点击偶尔会派发两次 action（弹层开合都会回来一次），
        // 结果就是「刚弹出来又立刻收回去」。250ms 内的重复点击直接丢弃。
        let now = CACurrentMediaTime()
        if now - lastClickAt < 0.25 { return }
        lastClickAt = now

        let event = NSApp.currentEvent
        let isSecondary = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true

        // 按下点必须落在徽标内。菜单栏 action 的重放事件坐标是按别的窗口原点算的，
        // 直接用会把面板导到错误的段上——这正是「点 CPU 弹内存」的成因。
        let pressAge = now - pressAt
        let press = pressAge < 2 ? pressLocation : nil
        let evStamp = event.map { String(format: "%.3f", $0.timestamp) } ?? "nil"
        trace("ACTION t=\(String(format: "%.3f", now)) shown=\(popover?.isShown ?? false) "
              + "pressAge=\(String(format: "%.3f", pressAge)) press=\(String(describing: press)) "
              + "ev=\(evStamp)\n")

        if isSecondary {
            presentContextMenu()
            return
        }

        guard let press else {
            // 重放事件（不在徽标内）或键盘触发：保持现状，不做任何路由，
            // 否则面板会被这种幽灵点击切走。
            trace("ACTION ignored（按下点不在徽标内）\n")
            return
        }

        let slot = clickedSlot(at: press, in: sender)
        togglePopover(slot)
    }

    /// 把按下点（屏幕坐标，原点左下）换算到徽标图像坐标，再交给纯逻辑层分段。
    private func clickedSlot(at press: NSPoint, in button: NSStatusBarButton) -> MenuBarSlot {
        let visible = segments.map(\.slot)
        let fallback = visible.first ?? .network
        guard let frameInScreen = badgeScreenRect() else { return fallback }

        let point = NSPoint(x: press.x - frameInScreen.minX, y: press.y - frameInScreen.minY)
        let imageWidth = button.image?.size.width ?? button.bounds.width
        let originX = (button.bounds.width - imageWidth) / 2
        let x = point.x - originX
        let slot = MenuBarBadge.slot(atX: x, segments: segments) ?? fallback
        trace("HIT mouse=\(press) buttonScreen=\(frameInScreen.minX)…\(frameInScreen.maxX) "
              + "originX=\(originX) imageW=\(imageWidth) x=\(x) → \(slot)\n")
        return slot
    }

    private func togglePopover(_ slot: MenuBarSlot) {
        guard let button = item.button else { return }
        let popover = panelPopover()
        let now = CACurrentMediaTime()

        // 面板开着的时候点徽标 = 收起，**不区分点了哪一段**。
        // 换页交给面板里的选项栏（需求里的那排「清理释放 | 系统功能」），
        // 这样即便命中判定有 1pt 的偏差，也不会出现「想关却换了个页」。
        //
        // `.transient` 的面板在鼠标按下时就先被系统收起，动作回调随后才到，
        // 所以「刚自动收起过」也要按收起处理，否则会立刻又弹回来。
        if popover.isShown || now - lastAutoCloseAt < 0.4 {
            if popover.isShown {
                suppressCloseTracking = true
                popover.performClose(nil)
            }
            currentSlot = nil
            lastAutoCloseAt = 0
            trace("POPOVER closed-by-badge\n")
            return
        }

        router.route(to: slot)
        settings.refreshLoginItemStatus()
        // 面板每次打开都把历史统计刷一遍（内部先 flush 再查库），
        // 否则昨天关掉的应用今天的最新累计看不到。实时档不查库；demo 模式内部会跳过。
        if let granularity = router.trafficRange.granularity {
            engine.refreshHistory(range: granularity)
        }
        // 先激活自己：accessory 应用不激活的话，popover 会在鼠标移开时被系统收起，
        // 面板里的悬停/键盘( Esc ) 交互也会因为不是 key window 而失效。
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: anchorRect(for: slot, in: button),
                     of: button,
                     preferredEdge: .minY)
        currentSlot = slot
        if let window = popover.contentViewController?.view.window {
            window.makeKey()
            // 面板里的行要在鼠标划过时显示「关闭」，这依赖 mouseMoved 事件；
            // popover 默认不保证接收，显式打开。
            window.acceptsMouseMovedEvents = true
        }
        trace("POPOVER \(slot) shown=\(popover.isShown) "
              + "window=\(popover.contentViewController?.view.window?.windowNumber ?? -1)\n")
    }

    /// 该段在按钮坐标系里的矩形，作为 popover 的锚点
    private func anchorRect(for slot: MenuBarSlot, in button: NSStatusBarButton) -> NSRect {
        guard let segment = segments.first(where: { $0.slot == slot }) else {
            return button.bounds
        }
        let imageWidth = button.image?.size.width ?? 0
        let originX = (button.bounds.width - imageWidth) / 2
        return NSRect(x: originX + segment.frame.minX,
                      y: (button.bounds.height - segment.frame.height) / 2,
                      width: segment.frame.width,
                      height: segment.frame.height)
    }

    private func closeAllPopovers() {
        // 这些是程序内部主动收起（右键菜单、被关掉的段从徽标移除），
        // 不该被记成「用户点徽标收起」，否则下一次点徽标会白点一次
        if popover?.isShown == true { suppressCloseTracking = true }
        popover?.performClose(nil)
        currentSlot = nil
    }

    private func presentContextMenu() {
        let menu = NSMenu()

        // 段开关放最上面：菜单栏挤的时候这是最先要找的地方
        for target in MenuBarSlot.allCases {
            let entry = NSMenuItem(title: target.title,
                                   action: #selector(toggleSlotVisibility(_:)),
                                   keyEquivalent: "")
            entry.target = self
            entry.tag = target.rawValue
            entry.state = isVisible(target) ? .on : .off
            menu.addItem(entry)
        }

        menu.addItem(.separator())

        let pauseItem = NSMenuItem(
            title: engine.isPausedNow ? "继续监控" : "暂停监控",
            action: #selector(togglePause),
            keyEquivalent: ""
        )
        pauseItem.target = self
        menu.addItem(pauseItem)

        menu.addItem(.separator())

        let styleMenu = NSMenu()
        for (index, style) in Settings.NetworkBarStyle.allCases.enumerated() {
            let entry = NSMenuItem(title: style.label,
                                   action: #selector(selectNetworkBarStyle(_:)),
                                   keyEquivalent: "")
            entry.target = self
            entry.tag = index
            entry.state = settings.networkBarStyle == style ? .on : .off
            styleMenu.addItem(entry)
        }
        let styleItem = NSMenuItem(title: "网络图标", action: nil, keyEquivalent: "")
        styleItem.submenu = styleMenu
        menu.addItem(styleItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出 NetScope", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        closeAllPopovers()
        // 「临时挂菜单 → 触发点击 → 立即解绑」：长期绑定 menu 后左键就再也弹不出 popover 了
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func togglePause() {
        engine.togglePause()
        updateBadge()
    }

    @objc private func selectNetworkBarStyle(_ sender: NSMenuItem) {
        let styles = Settings.NetworkBarStyle.allCases
        guard sender.tag >= 0, sender.tag < styles.count else { return }
        settings.networkBarStyle = styles[sender.tag]
        updateBadge()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - 可见性

    private func isVisible(_ slot: MenuBarSlot) -> Bool {
        switch slot {
        case .cpu: return settings.menuBarShowsCPU
        case .memory: return settings.menuBarShowsMemory
        case .network: return settings.menuBarShowsNetwork
        }
    }

    private func setVisible(_ visible: Bool, for slot: MenuBarSlot) {
        switch slot {
        case .cpu: settings.menuBarShowsCPU = visible
        case .memory: settings.menuBarShowsMemory = visible
        case .network: settings.menuBarShowsNetwork = visible
        }
    }

    @objc private func toggleSlotVisibility(_ sender: NSMenuItem) {
        guard let slot = MenuBarSlot(rawValue: sender.tag) else { return }
        let target = !isVisible(slot)
        if !target, MenuBarSlot.allCases.allSatisfy({ $0 == slot || !isVisible($0) }) {
            // 三段全关就彻底没有入口了（accessory 应用连 Dock 图标都没有）
            NSSound.beep()
            return
        }
        setVisible(target, for: slot)
        if !target, currentSlot == slot { closeAllPopovers() }
        updateBadge()
    }

    // MARK: - 徽标

    private func state() -> MenuBarBadge.State {
        let load = engine.systemLoad
        var visible: Set<MenuBarSlot> = []
        if settings.menuBarShowsCPU { visible.insert(.cpu) }
        if settings.menuBarShowsMemory { visible.insert(.memory) }
        if settings.menuBarShowsNetwork { visible.insert(.network) }
        if visible.isEmpty { visible.insert(.network) }

        return MenuBarBadge.State(
            cpu: load.cpuReady ? load.cpuPercent : nil,
            memory: load.memory?.percent,
            up: engine.totalUp,
            down: engine.totalDown,
            networkGlyph: settings.networkBarStyle == .sparkline ? .sparkline : .rate,
            sparkline: engine.history,
            visible: visible
        )
    }

    private func updateBadge() {
        guard let button = item.button else { return }
        let rendered = MenuBarBadge.render(state())
        segments = rendered.segments
        button.image = rendered.image
        button.imagePosition = .imageOnly
        button.toolTip = tooltip()
        // 排障用：菜单栏别的状态项一增减，徽标就会整体平移，
        // 自动化点击的固定坐标随之失效。位置变了就记一行，方便换算。
        if Self.traceClicks, let rect = badgeScreenRect() {
            let signature = "\(Int(rect.minX)),\(Int(rect.width))"
            if signature != lastTraceRect {
                lastTraceRect = signature
                trace("RECT x=\(Int(rect.minX)) w=\(Int(rect.width))\n")
            }
        }
    }

    private func tooltip() -> String {
        let prefix = engine.isPausedNow ? "已暂停 · " : ""
        let load = engine.systemLoad
        var parts: [String] = []
        if isVisible(.cpu) {
            var text = "CPU \(PercentFormat.text(load.cpuReady ? load.cpuPercent : nil))"
            if let breakdown = load.breakdown {
                text += "（用户 \(Int(breakdown.user.rounded()))% / 系统 \(Int(breakdown.system.rounded()))%）"
            }
            parts.append(text)
        }
        if isVisible(.memory), let memory = load.memory {
            parts.append("内存 \(Int(memory.percent.rounded()))%（\(ByteFormat.size(memory.used)) / \(ByteFormat.size(memory.total))）")
        }
        if isVisible(.network) {
            parts.append("上行 \(ByteFormat.rate(engine.totalUp))，下行 \(ByteFormat.rate(engine.totalDown))")
        }
        return prefix + parts.joined(separator: " · ")
    }

    // MARK: - 调试入口

    /// 供无界面自检 / 调试使用：直接打开指定段的面板。
    func showPanel(_ slot: MenuBarSlot = .network) {
        guard let button = item.button else { return }
        let popover = panelPopover()
        router.route(to: slot)
        guard !popover.isShown else { return }
        popover.show(relativeTo: anchorRect(for: slot, in: button),
                     of: button,
                     preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        currentSlot = slot
    }

    /// 截图专用：关掉 transient 自动收起（脚本启动时应用从未激活，
    /// 任何焦点变化都会让面板瞬间消失），并把窗口号打到 stdout 供 `screencapture -l` 使用。
    func presentPanelForCapture(slot: MenuBarSlot = .network) {
        let popover = panelPopover()
        router.route(to: slot)
        popover.behavior = .applicationDefined
        NSApp.activate(ignoringOtherApps: true)
        showPanel(slot)
        setvbuf(stdout, nil, _IONBF, 0)
        if let button = item.button {
            let onScreen = button.window?.frame ?? .zero
            print("STATUS_BUTTON frame=\(Int(button.frame.width))x\(Int(button.frame.height)) "
                  + "windowX=\(Int(onScreen.origin.x)) visible=\(!button.isHidden) "
                  + "segments=\(segments.count)")
        }
        if let window = popover.contentViewController?.view.window {
            print("PANEL_WINDOW=\(window.windowNumber)")
        }
    }

    /// 面板是否可见，供外部脚本核对。
    var isPanelVisible: Bool { popover?.isShown ?? false }

    /// 打印徽标与各段的屏幕坐标。合并成一项后仍值得核对：
    /// 若整块被挤到刘海下面，`screenX` 会是负数或与刘海重叠。
    func dumpMenuBarGeometry() {
        guard let button = item.button else {
            print("menu: 无 button")
            return
        }
        let imageSize = button.image?.size ?? .zero
        let frame = button.window?.convertToScreen(button.convert(button.bounds, to: nil)) ?? .zero
        print("menu: image=\(Int(imageSize.width))x\(Int(imageSize.height)) "
              + "screenX=\(Int(frame.origin.x)) screenY=\(Int(frame.origin.y)) "
              + "w=\(Int(frame.width)) h=\(Int(frame.height))")
        // 菜单栏挤满时 macOS 不会报错：item 仍在、坐标照算，但窗口被移出可视区或隐藏。
        // 这三个值能区分「代码没画」和「系统没地方放」。
        print("menu: isVisible=\(item.isVisible) buttonHidden=\(button.isHidden) "
              + "windowVisible=\(button.window?.isVisible ?? false) "
              + "occluded=\(button.window?.occlusionState.contains(.visible) == false)")
        let originX = (button.bounds.width - imageSize.width) / 2
        for segment in segments {
            let rect = NSRect(x: originX + segment.frame.minX, y: 0,
                              width: segment.frame.width, height: button.bounds.height)
            let screen = button.window?.convertToScreen(button.convert(rect, to: nil)) ?? .zero
            print("  \(segment.slot): x=\(Int(screen.origin.x)) w=\(Int(screen.width))")
        }
        // 命中分区：把按钮横坐标逐点换算成槽位，用来核对「点哪里算谁的」。
        print("menu: 命中分区 originX=\(Int(originX)) imageW=\(Int(imageSize.width))")
        var probe: CGFloat = 0
        while probe <= button.bounds.width {
            let hit = MenuBarBadge.slot(atX: probe - originX, segments: segments)
            print("  buttonX=\(Int(probe)) → \(hit.map { String(describing: $0) } ?? "nil")")
            probe += 4
        }
    }

    /// 退出前必须显式停掉采样器：nettop 是子进程，主进程被信号终止时
    /// 内核不会替我们回收它，会留下孤儿进程持续占 CPU。
    func shutdown() {
        engine.shutdown()
    }
}

extension StatusItemController: NSPopoverDelegate {
    /// 只记「非我方触发」的收起：点到面板外、按 Esc、系统失焦都走这里，
    /// 下一次点徽标就能据此识别成收起而不是重开。
    func popoverDidClose(_ notification: Notification) {
        if suppressCloseTracking {
            suppressCloseTracking = false
            trace("CLOSE suppressed slot=\(String(describing: currentSlot))\n")
            return
        }
        lastAutoCloseAt = CACurrentMediaTime()
        trace("CLOSE auto t=\(String(format: "%.3f", lastAutoCloseAt)) "
              + "slot=\(String(describing: currentSlot))\n")
        currentSlot = nil
    }
}
