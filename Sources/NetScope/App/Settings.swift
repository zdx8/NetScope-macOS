import Foundation
import AppKit
import ServiceManagement
import Combine

/// 用户偏好。用显式 didSet 写 UserDefaults 而不是 `@AppStorage`：
/// `@AppStorage` 在 ObservableObject 里不会触发 objectWillChange，界面不会跟着刷新。
final class Settings: ObservableObject {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let interval = "sampleInterval"
        static let rows = "maxVisibleRows"
        /// 1.1.4 之前控制菜单栏趋势图的布尔开关，只用于迁移
        static let legacySparkline = "showMenuBarSparkline"
        /// 1.1.4 的「速率 / 趋势 / 负载」三态，1.1.5 起拆分，只用于迁移
        static let legacyStyle = "menuBarStyle"
        static let networkBarStyle = "networkBarStyle"
        static let showCPUItem = "menuBarShowsCPU"
        static let showMemoryItem = "menuBarShowsMemory"
        static let showNetworkItem = "menuBarShowsNetwork"
        static let alerts = "alertsEnabled"
        static let alertThreshold = "alertThresholdMBps"
        static let physicalOnly = "physicalOnlyList"
        static let appearanceTheme = "appearanceTheme"
    }

    /// 面板主题。为什么用 NSAppearance 而不是 `.environment(\.colorScheme)`：
    /// Theme 的语义色是 NSColor 动态色（按视图 effectiveAppearance 解析），
    /// 环境值只覆盖 SwiftUI 内容；在面板宿主视图上设 appearance 两边一起切。
    enum AppearanceTheme: String, CaseIterable, Identifiable {
        case system
        case light
        case dark

        var id: String { rawValue }

        var label: String {
            switch self {
            case .system: return "跟随系统"
            case .light: return "浅色"
            case .dark: return "深色"
            }
        }

        /// 强制外观；跟随系统返回 nil（继承系统，含系统的实时切换）。
        /// 只作用于弹出面板；菜单栏徽标跟随菜单栏自身的深浅，不在这里强制。
        var nsAppearance: NSAppearance? {
            switch self {
            case .system: return nil
            case .light: return NSAppearance(named: .aqua)
            case .dark: return NSAppearance(named: .darkAqua)
            }
        }
    }

    /// 网络那一项在菜单栏里的形态。CPU / 内存各有独立菜单栏项之后，
    /// 这里不再需要「负载」选项 —— 那两种指标已经拆成单独的可见项。
    enum NetworkBarStyle: String, CaseIterable, Identifiable {
        case rate
        case sparkline

        var id: String { rawValue }

        var label: String {
            switch self {
            case .rate: return "速率"
            case .sparkline: return "趋势"
            }
        }
    }

    /// nettop 采样间隔（秒）。nettop 的 `-s` 只接受整数，故限定 1–5。
    ///
    /// ⚠️ 不要在 didSet 里给它自己重新赋值（钳制）来"纠正"非法值：
    /// `@Published` 的 setter 每次都会 `objectWillChange.send()`，在 Picker 的回调里
    /// 二次赋值等于在视图更新期间再发布一次变更，实测会让 App 直接闪退。
    /// 取值范围由 UI（只提供 1/2/3/5）和 init 里的钳制来保证。
    @Published var sampleInterval: Int {
        didSet { defaults.set(sampleInterval, forKey: Key.interval) }
    }

    /// 弹出面板里最多显示多少个应用。
    @Published var maxVisibleRows: Int {
        didSet { defaults.set(maxVisibleRows, forKey: Key.rows) }
    }

    /// 网络项在菜单栏里的图标形态（速率 / 趋势图）。
    @Published var networkBarStyle: NetworkBarStyle {
        didSet { defaults.set(networkBarStyle.rawValue, forKey: Key.networkBarStyle) }
    }

    /// 菜单栏三项各自独立可见。关掉某一项时它对应的 statusItem 直接 `isVisible = false`，
    /// 而不是销毁重建 —— 重建会让右侧其余图标左右跳一下。
    @Published var menuBarShowsCPU: Bool {
        didSet { defaults.set(menuBarShowsCPU, forKey: Key.showCPUItem) }
    }

    @Published var menuBarShowsMemory: Bool {
        didSet { defaults.set(menuBarShowsMemory, forKey: Key.showMemoryItem) }
    }

    @Published var menuBarShowsNetwork: Bool {
        didSet { defaults.set(menuBarShowsNetwork, forKey: Key.showNetworkItem) }
    }

    /// 某个应用持续占用带宽时发系统通知。
    @Published var alertsEnabled: Bool {
        didSet { defaults.set(alertsEnabled, forKey: Key.alerts) }
    }

    /// 告警阈值（MB/s）。低于 0.1 视为无效 —— 钳制放在 init 与 UI 侧，理由同上。
    @Published var alertThresholdMBps: Double {
        didSet { defaults.set(alertThresholdMBps, forKey: Key.alertThreshold) }
    }

    /// 列表只统计物理链路（此时各行之和不含 VPN 加密副本，但看不到走隧道内的应用）。
    @Published var physicalOnlyList: Bool {
        didSet { defaults.set(physicalOnlyList, forKey: Key.physicalOnly) }
    }

    /// 面板主题（跟随系统 / 浅色 / 深色）。
    @Published var appearanceTheme: AppearanceTheme {
        didSet { defaults.set(appearanceTheme.rawValue, forKey: Key.appearanceTheme) }
    }

    /// 开机自动启动。状态以 SMAppService 为准，写失败时回滚开关。
    @Published var launchAtLogin: Bool {
        didSet {
            guard !isSyncingLoginItem, launchAtLogin != loginItemEnabled else { return }
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("NetScope: 设置开机启动失败 — \(error.localizedDescription)")
                isSyncingLoginItem = true
                launchAtLogin = loginItemEnabled
                isSyncingLoginItem = false
            }
        }
    }

    private var isSyncingLoginItem = false

    var loginItemEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    private init() {
        let storedInterval = defaults.object(forKey: Key.interval) as? Int ?? 1
        sampleInterval = min(max(storedInterval, 1), 5)
        let storedRows = defaults.object(forKey: Key.rows) as? Int ?? 8
        maxVisibleRows = min(max(storedRows, 3), 15)
        launchAtLogin = SMAppService.mainApp.status == .enabled

        // 菜单栏形态迁移（1.1.5）：1.1.4 是「速率 / 趋势 / 负载」三态单开关，
        // 现在拆成「网络项用速率还是趋势」+「CPU / 内存项各自开关」。
        // 旧的 ".load" 表示用户只想看负载 → 保留 CPU / 内存两项、网络项默认也开着，
        // 宁可多一项也能一键在右键菜单里关掉，不要升级后突然少了他要的指标。
        if let raw = defaults.string(forKey: Key.networkBarStyle),
           let style = NetworkBarStyle(rawValue: raw) {
            networkBarStyle = style
        } else if defaults.string(forKey: Key.legacyStyle) == "sparkline"
                    || defaults.object(forKey: Key.legacySparkline) as? Bool == true {
            networkBarStyle = .sparkline
        } else {
            networkBarStyle = .rate
        }

        menuBarShowsCPU = defaults.object(forKey: Key.showCPUItem) as? Bool ?? true
        menuBarShowsMemory = defaults.object(forKey: Key.showMemoryItem) as? Bool ?? true
        menuBarShowsNetwork = defaults.object(forKey: Key.showNetworkItem) as? Bool ?? true

        alertsEnabled = defaults.bool(forKey: Key.alerts)
        let threshold = defaults.object(forKey: Key.alertThreshold) as? Double ?? 5.0
        alertThresholdMBps = min(max(threshold, 0.1), 1000)
        physicalOnlyList = defaults.bool(forKey: Key.physicalOnly)
        appearanceTheme = defaults.string(forKey: Key.appearanceTheme)
            .flatMap(AppearanceTheme.init(rawValue:)) ?? .system
    }

    /// 重新从系统读取开机启动状态（用户可能在系统设置里改过）。
    func refreshLoginItemStatus() {
        guard launchAtLogin != loginItemEnabled else { return }
        isSyncingLoginItem = true
        launchAtLogin = loginItemEnabled
        isSyncingLoginItem = false
    }
}
