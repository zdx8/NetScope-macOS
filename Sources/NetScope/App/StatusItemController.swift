import AppKit
import SwiftUI
import Combine

/// 菜单栏项 + 弹出面板的宿主。
@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let engine = MonitorEngine()
    private let settings = Settings.shared
    private var cancellables: Set<AnyCancellable> = []

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureButton()
        configurePopover()
        bindUpdates()
        engine.start()
    }

    /// 供无界面自检使用
    var monitorEngine: MonitorEngine { engine }

    // MARK: - 装配

    private func configureButton() {
        guard let button = statusItem.button else { return }
        // "network" 在菜单栏小尺寸下辨识度差（三点连线的缩略图），换成上下箭头
        let image = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: "NetScope")
            ?? NSImage(systemSymbolName: "network", accessibilityDescription: "NetScope")
        image?.isTemplate = true
        button.image = settings.showMenuBarSparkline
            ? MenuBarSparkline.image(history: engine.history)
            : MenuBarBadge.image(up: engine.totalUp, down: engine.totalDown)
        button.isBordered = false
        button.imagePosition = .imageLeading
        button.imageScaling = .scaleProportionallyDown
        button.target = self
        button.action = #selector(handleButtonClick)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "NetScope — 应用网络流量"
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        let initialMode: PanelView.PanelMode =
            CommandLine.arguments.contains("--show-history") ? .history : .live
        let showSettings = CommandLine.arguments.contains("--show-settings")
        let host = NSHostingController(
            rootView: PanelView(engine: engine, settings: settings,
                                initialMode: initialMode,
                                showSettingsInitially: showSettings)
        )
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.contentSize = NSSize(width: 348, height: 460)
    }

    private func bindUpdates() {
        // 趋势图要跟着每次采样走
        engine.$history
            .sink { [weak self] _ in
                Task { @MainActor in self?.updateMenuBar() }
            }
            .store(in: &cancellables)

        engine.$totalDown
            .sink { [weak self] _ in
                Task { @MainActor in self?.updateMenuBar() }
            }
            .store(in: &cancellables)

        engine.$status
            .sink { [weak self] _ in
                Task { @MainActor in self?.updateMenuBar() }
            }
            .store(in: &cancellables)

        settings.$showMenuBarSparkline
            .sink { [weak self] _ in
                Task { @MainActor in self?.updateMenuBar() }
            }
            .store(in: &cancellables)
    }

    // MARK: - 交互

    @objc private func handleButtonClick() {
        guard let event = NSApp.currentEvent else {
            togglePopover()
            return
        }
        let isSecondary = event.type == .rightMouseUp || event.modifierFlags.contains(.control)
        if isSecondary {
            presentContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem.button else { return }
        settings.refreshLoginItemStatus()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func presentContextMenu() {
        let menu = NSMenu()

        let pauseItem = NSMenuItem(
            title: engine.isPausedNow ? "继续监控" : "暂停监控",
            action: #selector(togglePause),
            keyEquivalent: ""
        )
        pauseItem.target = self
        menu.addItem(pauseItem)

        let sparklineItem = NSMenuItem(
            title: "菜单栏显示趋势图",
            action: #selector(toggleSparkline),
            keyEquivalent: ""
        )
        sparklineItem.target = self
        sparklineItem.state = settings.showMenuBarSparkline ? .on : .off
        menu.addItem(sparklineItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出 NetScope", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        if popover.isShown { popover.performClose(nil) }
        // 用「临时挂菜单 → 触发点击 → 立即解绑」的方式弹出右键菜单，
        // 否则 statusItem 会长期绑定 menu，左键就再也弹不出 popover 了。
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func togglePause() {
        engine.togglePause()
        updateMenuBar()
    }

    @objc private func toggleSparkline() {
        settings.showMenuBarSparkline.toggle()
        updateMenuBar()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - 菜单栏外观

    private func updateMenuBar() {
        guard let button = statusItem.button else { return }

        // 两种形态都是 template image，由系统按深浅色自动反色
        if settings.showMenuBarSparkline {
            button.image = MenuBarSparkline.image(history: engine.history)
        } else {
            button.image = MenuBarBadge.image(up: engine.totalUp, down: engine.totalDown)
        }
        button.imagePosition = .imageOnly

        button.toolTip = engine.isPausedNow
            ? "NetScope — 已暂停"
            : "NetScope — 上行 \(ByteFormat.rate(engine.totalUp))，下行 \(ByteFormat.rate(engine.totalDown))"
    }

    /// 供无界面自检 / 调试使用：直接打开弹出面板。
    func showPanel() {
        guard !popover.isShown, let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    /// 截图专用：关掉 transient 自动收起（否则脚本启动时应用从未激活，
    /// 任何焦点变化都会让面板瞬间消失），并把窗口号打到 stdout 供 `screencapture -l` 使用。
    func presentPanelForCapture() {
        popover.behavior = .applicationDefined
        NSApp.activate(ignoringOtherApps: true)
        showPanel()
        setvbuf(stdout, nil, _IONBF, 0)
        if let button = statusItem.button {
            let onScreen = button.window?.frame ?? .zero
            print("STATUS_BUTTON frame=\(Int(button.frame.width))x\(Int(button.frame.height)) "
                  + "windowX=\(Int(onScreen.origin.x)) visible=\(!button.isHidden)")
        }
        if let window = popover.contentViewController?.view.window {
            print("PANEL_WINDOW=\(window.windowNumber)")
        }
    }

    /// 面板是否可见，供外部脚本核对。
    var isPanelVisible: Bool { popover.isShown }

    /// 退出前必须显式停掉采样器：nettop 是子进程，主进程被信号终止时
    /// 内核不会替我们回收它，会留下孤儿进程持续占 CPU。
    func shutdown() {
        engine.shutdown()
    }
}
