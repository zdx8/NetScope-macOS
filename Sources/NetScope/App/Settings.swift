import Foundation
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
        static let sparkline = "showMenuBarSparkline"
        static let alerts = "alertsEnabled"
        static let alertThreshold = "alertThresholdMBps"
        static let physicalOnly = "physicalOnlyList"
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

    /// 菜单栏用迷你趋势图替代静态图标。
    @Published var showMenuBarSparkline: Bool {
        didSet { defaults.set(showMenuBarSparkline, forKey: Key.sparkline) }
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
        // 默认用「网络图标 + 双行数值」：菜单栏里一眼能看到上下行各是多少。
        // 趋势图是可选形态（右键菜单可切），比数值宽 10pt 且不含具体数字。
        showMenuBarSparkline = defaults.object(forKey: Key.sparkline) as? Bool ?? false
        alertsEnabled = defaults.bool(forKey: Key.alerts)
        let threshold = defaults.object(forKey: Key.alertThreshold) as? Double ?? 5.0
        alertThresholdMBps = min(max(threshold, 0.1), 1000)
        physicalOnlyList = defaults.bool(forKey: Key.physicalOnly)
    }

    /// 重新从系统读取开机启动状态（用户可能在系统设置里改过）。
    func refreshLoginItemStatus() {
        guard launchAtLogin != loginItemEnabled else { return }
        isSyncingLoginItem = true
        launchAtLogin = loginItemEnabled
        isSyncingLoginItem = false
    }
}
