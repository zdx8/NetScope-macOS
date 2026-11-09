import AppKit
import Combine

struct AppTrafficRow: Identifiable {
    let id: String
    let name: String
    let icon: NSImage?
    let down: Double
    let up: Double
    let isApplication: Bool
    /// 聚合出来的「其他 N 个应用」行，样式略有区别
    let isAggregate: Bool
    /// VPN 客户端：它显示的流量是物理链路上的加密字节，口径与总量一致但与其他应用互为副本
    var isTunnelClient: Bool = false

    var total: Double { down + up }
}

/// 把采样器、差分器、进程目录、用户偏好串起来，向界面暴露一份可直接渲染的快照。
///
/// 两条采样通道：
/// - `appChannel`（`.external`）—— 提供**应用归属**，能看到走 VPN 隧道内的应用
/// - `netChannel`（`.physical`）—— 提供**总量**，只算真实网卡字节
///
/// 只用一条通道无法同时满足两者：全接口会把 VPN 加密开销和应用明文各算一次（总量翻倍），
/// 只算物理接口则看不到隧道内的应用（列表里只剩 VPN 客户端）。
@MainActor
final class MonitorEngine: ObservableObject {
    enum Status: Equatable {
        case starting
        case running
        case paused
        case failed(String)

        var label: String {
            switch self {
            case .starting: return "启动中"
            case .running: return "实时"
            case .paused: return "已暂停"
            case .failed(let reason): return "异常：\(reason)"
            }
        }
    }

    // 供界面渲染
    @Published private(set) var status: Status = .starting
    @Published private(set) var rows: [AppTrafficRow] = []
    @Published private(set) var totalDown: Double = 0
    @Published private(set) var totalUp: Double = 0
    @Published private(set) var sessionDown: UInt64 = 0
    @Published private(set) var sessionUp: UInt64 = 0
    @Published private(set) var history = RateHistory(capacity: 60)
    @Published private(set) var sampleCount = 0
    @Published private(set) var lastSampleAt: Date?
    @Published private(set) var processCount = 0
    /// 当前显示的这批应用里最大的吞吐，用于把进度条归一化
    @Published private(set) var peakRowTotal: Double = 0

    // VPN 相关
    /// 系统存在带 IPv4 地址的 utun 接口
    @Published private(set) var isTunnelActive = false
    @Published private(set) var tunnelNames: [String] = []
    /// 总量是否来自物理网卡通道（false 表示已退化为全接口合计）
    @Published private(set) var isUsingPhysicalTotal = true

    // 历史（按天持久化）
    @Published private(set) var todayTotal: UInt64 = 0
    @Published private(set) var weekTotal: UInt64 = 0
    @Published private(set) var topAppsInHistory: [HistoryStore.AppEntry] = []
    @Published private(set) var dailyTotals: [HistoryStore.DayTotal] = []
    @Published private(set) var historyAvailable = false

    private let appChannel = TrafficChannel(scope: .external)
    private let netChannel = TrafficChannel(scope: .physical)
    private let directory = ProcessDirectory()
    private let settings: Settings
    private let alertCenter = AlertCenter()
    private let historyStore: HistoryStore?
    private var cancellables: Set<AnyCancellable> = []

    private var watchdog: Timer?
    private var isPaused = false
    private var currentInterval = 1
    private var batchesSincePrune = 0

    private var lastAppRestartAt = Date.distantPast
    private var lastNetRestartAt = Date.distantPast
    private var lastTunnelCheck = Date.distantPast
    private var netChannelAbandoned = false

    init(settings: Settings = .shared, requestNotificationPermission: Bool = true) {
        self.settings = settings
        self.historyStore = HistoryStore.defaultPath().flatMap { HistoryStore(path: $0) }
        self.historyAvailable = historyStore != nil
        // headless 自检不请求通知权限，避免在无人值守时弹出系统授权对话框
        if settings.alertsEnabled && requestNotificationPermission {
            alertCenter.requestAuthorizationIfNeeded()
        }
        observeSettings()
    }

    var isPausedNow: Bool { isPaused }

    // MARK: - 生命周期

    func start() {
        isPaused = false
        refreshTunnelState(force: true)
        launchChannels()
        startWatchdog()
    }

    func stop() {
        watchdog?.invalidate()
        watchdog = nil
        appChannel.stop()
        netChannel.stop()
        historyStore?.flush(force: true)
        status = .paused
    }

    /// 退出前调用：停采样并关闭数据库，保证 WAL 落盘。
    func shutdown() {
        stop()
        historyStore?.close()
    }

    /// 读取历史统计（切换到历史视图时调用）。先 flush 一次，让刚采集的数据也能看到。
    func refreshHistory() {
        guard let historyStore else { return }
        historyStore.flush(force: true)
        todayTotal = historyStore.total(days: 1).total
        weekTotal = historyStore.total(days: 7).total
        topAppsInHistory = historyStore.topApps(limit: 6)
        dailyTotals = historyStore.dailyTotals(days: 7)
    }

    func togglePause() {
        if isPaused || status == .paused {
            start()
        } else {
            isPaused = true
            watchdog?.invalidate()
            watchdog = nil
            appChannel.stop()
            netChannel.stop()
            status = .paused
        }
    }

    /// 清空本次会话的累计与曲线，不动采样。
    func resetSession() {
        sessionDown = 0
        sessionUp = 0
        history.clear()
    }

    private func launchChannels() {
        currentInterval = settings.sampleInterval
        status = sampleCount == 0 ? .starting : .running

        // 列表口径可以切到"只统计物理链路"：此时各行之和不含 VPN 加密副本，
        // 但走隧道内的应用也会消失（它们的 socket 在 utun 上）。
        let listScope: InterfaceScope = settings.physicalOnlyList ? .physical : .external

        appChannel.onBatch = { [weak self] delta, processCount in
            self?.applyApps(delta: delta, processCount: processCount)
        }
        appChannel.onFailure = { [weak self] reason in
            self?.handleAppFailure(reason)
        }
        appChannel.start(interval: currentInterval, scope: listScope)

        netChannel.onBatch = { [weak self] delta, _ in
            self?.applyNetwork(delta: delta)
        }
        netChannel.onFailure = { _ in
            // 物理通道失败不影响主流程：只是总量会退化为全接口合计，
            // 由 checkHealth 里的连续失败计数负责降级。
        }
        netChannel.start(interval: currentInterval)
    }

    // MARK: - 采样入库

    private func applyApps(delta: BatchDelta, processCount: Int) {
        guard !isPaused else { return }
        if status == .starting { status = .running }

        var keyByPID: [Int32: String] = [:]
        var identityByKey: [String: ProcessIdentity] = [:]
        for row in delta.processes {
            let identity = directory.identity(for: row.pid, rawName: row.rawName)
            keyByPID[row.pid] = identity.key
            identityByKey[identity.key] = identity
        }

        // VPN 应用照常展示，不做剔除。
        // 它在本通道里的流量是物理链路上的真实字节（客户端把明文加密后送上网卡），
        // 所以删掉它反而会漏统计；"同一份数据被算两次"的问题由总量侧解决 ——
        // 总量走 .physical 通道，只算网卡真正跑过的字节。
        let candidates = delta.processes

        let merged = AppAggregation.merge(candidates) { keyByPID[$0.pid] ?? $0.rawName }
        // 只保留本周期真有流量的条目。nettop 会把「持着 socket 但从没传过数据」的进程
        // 一并列出（实测 32 个进程里 16 个是 0 B/s），全列出来只会把真正占带宽的应用挤下去。
        let active = merged.filter { $0.downPerSecond + $0.upPerSecond > 0 }
        let limit = settings.maxVisibleRows

        var built: [AppTrafficRow] = []
        built.reserveCapacity(min(active.count, limit) + 1)
        for total in active.prefix(limit) {
            guard let identity = identityByKey[total.id] else { continue }
            built.append(AppTrafficRow(
                id: total.id,
                name: identity.displayName,
                icon: identity.icon,
                down: total.downPerSecond,
                up: total.upPerSecond,
                isApplication: identity.isApplication,
                isAggregate: false,
                isTunnelClient: isTunnelActive && TunnelDetector.isTunnelClient(identity.displayName)
            ))
        }

        if active.count > limit {
            let remainder = active.dropFirst(limit)
            let down = remainder.reduce(0.0) { $0 + $1.downPerSecond }
            let up = remainder.reduce(0.0) { $0 + $1.upPerSecond }
            built.append(AppTrafficRow(
                id: "__aggregate__",
                name: "其他 \(remainder.count) 个进程",
                icon: nil,
                down: down,
                up: up,
                isApplication: false,
                isAggregate: true
            ))
        }

        rows = built
        peakRowTotal = built.map(\.total).max() ?? 0
        self.processCount = processCount

        // 历史：按应用累计本周期增量，口径与面板列表一致（external）
        if let historyStore {
            var entries: [HistoryStore.AppEntry] = []
            entries.reserveCapacity(merged.count)
            for total in merged where total.deltaIn > 0 || total.deltaOut > 0 {
                let name = identityByKey[total.id]?.displayName ?? total.id
                entries.append(HistoryStore.AppEntry(key: total.id, name: name,
                                                     bytesIn: total.deltaIn, bytesOut: total.deltaOut))
            }
            if !entries.isEmpty { historyStore.record(entries) }
        }

        // 告警：只喂当前活跃的条目，避免 0 流量进程把连续计数表撑大
        if settings.alertsEnabled {
            let candidates = active.map { total in
                AlertCenter.Candidate(key: total.id,
                                      name: identityByKey[total.id]?.displayName ?? total.id,
                                      rate: total.downPerSecond + total.upPerSecond)
            }
            alertCenter.evaluate(candidates, threshold: settings.alertThresholdMBps * 1_000_000)
        } else {
            alertCenter.reset()
        }

        // 物理通道不可用时，总量退化为全接口合计（此时无法区分 VPN 加密开销）
        if !isUsingPhysicalTotal {
            updateTotals(down: delta.totalInPerSecond,
                         up: delta.totalOutPerSecond,
                         deltaIn: delta.totalInDelta,
                         deltaOut: delta.totalOutDelta)
        }

        // 定期清理已退出进程的缓存，避免长跑后字典膨胀
        batchesSincePrune += 1
        if batchesSincePrune >= 30 {
            batchesSincePrune = 0
            directory.prune(keeping: Set(delta.processes.map(\.pid)))
        }
    }

    private func applyNetwork(delta: BatchDelta) {
        guard !isPaused else { return }
        if !isUsingPhysicalTotal { isUsingPhysicalTotal = true }
        updateTotals(down: delta.totalInPerSecond,
                     up: delta.totalOutPerSecond,
                     deltaIn: delta.totalInDelta,
                     deltaOut: delta.totalOutDelta)
    }

    private func updateTotals(down: Double, up: Double, deltaIn: UInt64, deltaOut: UInt64) {
        totalDown = down
        totalUp = up
        sessionDown &+= deltaIn
        sessionUp &+= deltaOut
        history.append(down: down, up: up)
        sampleCount += 1
        lastSampleAt = Date()
    }

    // MARK: - VPN 状态

    private func refreshTunnelState(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastTunnelCheck) >= 30 else { return }
        lastTunnelCheck = now

        let names = TunnelDetector.activeTunnelNames()
        guard names != tunnelNames else { return }
        tunnelNames = names
        isTunnelActive = !names.isEmpty
    }

    // MARK: - 故障自愈

    private func handleAppFailure(_ reason: String) {
        if appChannel.consecutiveFailures >= 5 {
            status = .failed(reason)
            watchdog?.invalidate()
            watchdog = nil
        }
    }

    private func startWatchdog() {
        watchdog?.invalidate()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkHealth()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func checkHealth() {
        guard !isPaused else { return }
        refreshTunnelState()

        let now = Date()
        // 主通道沉默 → 重建子进程（5 秒节流，避免看门狗每 2 秒反复重启）
        if appChannel.isStalled, now.timeIntervalSince(lastAppRestartAt) > 5 {
            lastAppRestartAt = now
            appChannel.restart()
        }

        // 物理通道沉默 → 重建；连续失败则放弃，总量退化为全接口合计
        guard isUsingPhysicalTotal, !netChannelAbandoned else { return }
        if netChannel.isStalled, now.timeIntervalSince(lastNetRestartAt) > 5 {
            lastNetRestartAt = now
            if netChannel.consecutiveFailures >= 5 {
                abandonNetChannel()
            } else {
                netChannel.restart()
            }
        }
    }

    private func abandonNetChannel() {
        netChannelAbandoned = true
        isUsingPhysicalTotal = false
        netChannel.stop()
        NSLog("NetScope: 物理接口通道不可用，总量退化为全接口合计（VPN 去重暂时关闭）")
    }

    /// 供无界面自检使用：等待若干个样本。
    func waitForSamples(_ target: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if sampleCount >= target { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return sampleCount >= target
    }

    /// 仅供界面验收（`--demo`）：注入一组确定性的合成数据，覆盖
    /// 「曲线铺满 + 列表满档 + 含聚合行 + 超长应用名 + GB 级累计」这些
    /// 只有真实运行一分钟后才会出现的状态。正常路径不会走到这里。
    func loadDemoData(tunnelActive: Bool = false) {
        var demo = RateHistory(capacity: history.capacity)
        let slots = history.capacity
        for index in 0..<slots {
            let phase = Double(index) / Double(max(slots - 1, 1))
            let wave = 0.35 + 0.65 * (sin(phase * .pi * 3.1 - 1.2) + 1) / 2
            let tail = phase > 0.72 ? (phase - 0.72) / 0.28 * 0.55 : 0
            demo.append(down: (wave + tail) * 2_400_000,
                        up: (0.28 + 0.3 * (cos(phase * .pi * 2.2) + 1) / 2) * 330_000)
        }
        history = demo

        func appIcon(_ path: String) -> NSImage? {
            FileManager.default.fileExists(atPath: path)
                ? NSWorkspace.shared.icon(forFile: path)
                : nil
        }

        rows = [
            AppTrafficRow(id: "safari", name: "Safari", icon: appIcon("/Applications/Safari.app"),
                          down: 1_420_000, up: 96_400, isApplication: true, isAggregate: false),
            AppTrafficRow(id: "claude", name: "Claude", icon: appIcon("/Applications/Claude.app"),
                          down: 486_000, up: 21_600, isApplication: true, isAggregate: false),
            AppTrafficRow(id: "flclash", name: "FlClash", icon: appIcon("/Applications/FlClash.app"),
                          down: 240_000, up: 58_000, isApplication: true, isAggregate: false,
                          isTunnelClient: tunnelActive),
            AppTrafficRow(id: "baidunetdisk", name: "百度网盘", icon: appIcon("/Applications/BaiduNetdisk_mac.app"),
                          down: 128_000, up: 3_100, isApplication: true, isAggregate: false),
            AppTrafficRow(id: "wechat", name: "微信", icon: appIcon("/Applications/WeChat.app"),
                          down: 42_800, up: 88_200, isApplication: true, isAggregate: false),
            AppTrafficRow(id: "xcode", name: "Xcode", icon: appIcon("/Applications/Xcode.app"),
                          down: 12_400, up: 640, isApplication: true, isAggregate: false),
            AppTrafficRow(id: "renderer",
                          name: "com.apple.WebKit.WebContent.渲染进程",
                          icon: nil, down: 8_200, up: 1_900, isApplication: false, isAggregate: false),
            AppTrafficRow(id: "__aggregate__", name: "其他 12 个进程", icon: nil,
                          down: 6_100, up: 2_400, isApplication: false, isAggregate: true)
        ]

        totalDown = 2_106_000
        totalUp = 214_000
        sessionDown = 12_884_901_888
        sessionUp = 402_653_184
        processCount = 46
        peakRowTotal = rows.map(\.total).max() ?? 0
        status = .running

        isTunnelActive = tunnelActive
        tunnelNames = tunnelActive ? ["utun5"] : []
        isUsingPhysicalTotal = true
    }

    // MARK: - 偏好联动

    private func observeSettings() {
        settings.$sampleInterval
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] newValue in
                Task { @MainActor [weak self] in
                    guard let self, !self.isPaused else { return }
                    self.currentInterval = newValue
                    // 延迟一拍再重启：重建 nettop 要 kill + usleep(80ms) × 2 条通道，
                    // 在 segmented picker 的 action 里同步做会把主线程卡在这一帧，
                    // 实测就是「点刷新间隔就闪退」的触发条件。
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                        guard let self, !self.isPaused else { return }
                        self.appChannel.restart(interval: newValue)
                        if !self.netChannelAbandoned {
                            self.netChannel.restart(interval: newValue)
                        }
                    }
                }
            }
            .store(in: &cancellables)

        settings.$maxVisibleRows
            .dropFirst()
            .sink { [weak self] newValue in
                Task { @MainActor [weak self] in
                    guard let self, self.rows.count > newValue + 1 else { return }
                    // 直接裁剪，下一个采样周期会补齐「其他」行
                    self.rows = Array(self.rows.prefix(newValue))
                }
            }
            .store(in: &cancellables)

        settings.$physicalOnlyList
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] physicalOnly in
                Task { @MainActor [weak self] in
                    guard let self, !self.isPaused else { return }
                    // 同「刷新间隔」：换 scope 也要重建 nettop，不能在控件 action 里同步做
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                        guard let self, !self.isPaused else { return }
                        self.appChannel.restart(scope: physicalOnly ? .physical : .external)
                    }
                }
            }
            .store(in: &cancellables)

        settings.$alertsEnabled
            .dropFirst()
            .sink { [weak self] enabled in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if enabled {
                        self.alertCenter.requestAuthorizationIfNeeded()
                    } else {
                        self.alertCenter.reset()
                    }
                }
            }
            .store(in: &cancellables)
    }
}
