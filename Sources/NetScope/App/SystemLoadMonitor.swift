import AppKit
import Combine
import Foundation

/// 一行「程序占用」：按应用聚合后的 CPU 与内存。
///
/// 与网络列表同样是**应用级**口径：Chrome 的十几个 Helper 合成一条，
/// 否则前十行全是 `Google Chrome Helper (Renderer)`。
struct ProcessUsageRow: Identifiable {
    let id: String
    let name: String
    let icon: NSImage?
    /// 单核百分比（活动监视器口径，可超过 100%）
    let cpu: Double
    let memory: UInt64
    /// 占物理内存的百分比
    let memoryPercent: Double
    /// 合并了多少个进程
    let processCount: Int
    /// 参与聚合的 pid：行内「关闭」按钮用它们发 SIGTERM
    let pids: [Int32]

    var canClose: Bool { !pids.isEmpty }
}

/// 周期性采集系统 CPU / 内存占用 + 进程级占用，向界面暴露当前值与历史曲线。
///
/// 采样频率与网络采样共用 `sampleInterval`：三条曲线的时间轴一致，
/// 「近 N 秒」这类标注才不会自相矛盾。
@MainActor
final class SystemLoadMonitor: ObservableObject {
    @Published private(set) var cpuPercent: Double = 0
    /// 首次采样只建立基线，还没有可用的差分值；界面此时显示占位符
    @Published private(set) var cpuReady = false
    /// 用户态 / 内核态拆解，详情面板用来回答「这 X% 花在哪」
    @Published private(set) var breakdown: SystemLoadProbe.CPUBreakdown?
    @Published private(set) var memory: SystemLoadProbe.MemoryUsage?
    @Published private(set) var cpuHistory = LoadHistory(capacity: 60)
    @Published private(set) var memoryHistory = LoadHistory(capacity: 60)
    @Published private(set) var sampleCount = 0

    /// 按应用聚合后的进程占用。CPU 面板按 `cpu` 排序、内存面板按 `memory` 排序，
    /// 所以这里不做排序，交给视图（同一份数据两个消费者，排序键不同）。
    @Published private(set) var processRows: [ProcessUsageRow] = []
    @Published private(set) var processReady = false
    /// 磁盘 / 散热 / 开机时长（「系统功能」区块展示磁盘与网络状态；
    /// 散热与开机不再展示但继续采样，自检覆盖，恢复展示直接接回）
    @Published private(set) var stats: SystemStats?

    private var timer: Timer?
    private var lastTicks: SystemLoadProbe.CPUTicks?
    private var interval: TimeInterval = 1
    private var isRunning = false

    private let directory = ProcessDirectory()
    private static let processQueue = DispatchQueue(label: "com.zdx8.netscope.process-load",
                                                    qos: .utility)
    private var lastProcessTimes: [Int32: UInt64] = [:]
    private var lastProcessAt: Date?
    private var isSamplingProcesses = false
    private var processTicks = 0

    /// 幂等启动：间隔未变且定时器健在时直接返回，避免每次设置变更都重建。
    func start(interval seconds: Int) {
        let interval = TimeInterval(max(seconds, 1))
        if isRunning, timer != nil, interval == self.interval { return }
        stop()
        self.interval = interval
        isRunning = true

        // 先建立基线，第一次 fire 之后才有百分比可算
        lastTicks = SystemLoadProbe.cpuTicks()
        sampleMemory()
        sampleStats()
        sampleProcesses()

        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sample()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        isRunning = false
        timer?.invalidate()
        timer = nil
    }

    /// 清空曲线但保留当前读数（对应面板的「重置」）。
    func resetHistory() {
        cpuHistory.clear()
        memoryHistory.clear()
    }

    /// 当前采样间隔（秒）。详情面板用它把「60 个点」换算成「近 N 秒」。
    var sampleSeconds: Int { max(Int(interval.rounded()), 1) }

    private func sample() {
        if let current = SystemLoadProbe.cpuTicks() {
            if let previous = lastTicks,
               let percent = SystemLoadProbe.cpuPercent(previous: previous, current: current) {
                cpuPercent = percent
                cpuReady = true
                cpuHistory.append(percent)
                breakdown = SystemLoadProbe.cpuBreakdown(previous: previous, current: current)
            }
            lastTicks = current
        }
        sampleMemory()
        sampleProcesses()
        sampleStats()
        sampleCount += 1
    }

    /// 磁盘 / 散热 / 开机时长：都是廉价的系统调用，跟主采样同拍更新即可。
    /// （面板目前展示磁盘；散热与开机保留在 `SystemStats` 里，自检覆盖。）
    private func sampleStats() {
        if let stats = SystemStatsProbe.systemStats() { self.stats = stats }
    }

    private func sampleMemory() {
        guard let usage = SystemLoadProbe.memory() else { return }
        memory = usage
        memoryHistory.append(usage.percent)
    }

    // MARK: - 进程级采样

    /// 全量快照约 10 ms，必须离开主线程；算完再回主线程发布。
    /// 上一轮还没回来就跳过本轮，避免慢机器上任务堆积。
    private func sampleProcesses() {
        guard !isSamplingProcesses else { return }
        isSamplingProcesses = true
        let previous = lastProcessTimes
        let previousAt = lastProcessAt
        let startedAt = Date()

        Self.processQueue.async { [weak self] in
            let samples = ProcessLoadProbe.snapshot()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isSamplingProcesses = false
                self.apply(samples: samples, previous: previous,
                           previousAt: previousAt, startedAt: startedAt)
            }
        }
    }

    private func apply(samples: [ProcessLoadSample],
                       previous: [Int32: UInt64],
                       previousAt: Date?,
                       startedAt: Date) {
        // 第一次采样只建立基线：没有上一次就没有「占用率」，只有累计值和内存
        let percent = previousAt.map {
            ProcessLoadProbe.cpuPercents(previous: previous,
                                         current: samples,
                                         elapsed: startedAt.timeIntervalSince($0))
        } ?? [:]

        let total = ProcessInfo.processInfo.physicalMemory
        let merged = ProcessLoadProbe.merge(samples, percent: percent) { [directory] pid, raw in
            directory.identity(for: pid, rawName: raw.isEmpty ? "PID \(pid)" : raw).key
        }

        // 名字和图标只对聚合后的应用取一次（同 key 的多个 pid 结果相同）
        var identityByKey: [String: (name: String, icon: NSImage?, isApp: Bool)] = [:]
        for sample in samples {
            let identity = directory.identity(for: sample.pid,
                                              rawName: sample.name.isEmpty ? "PID \(sample.pid)" : sample.name)
            if identityByKey[identity.key] == nil {
                // nettop 名字被截断时 ProcessDirectory 已能反查；这里只补空名兜底
                let name = identity.displayName.isEmpty ? sample.name : identity.displayName
                identityByKey[identity.key] = (name, identity.icon, identity.isApplication)
            }
        }

        var rows: [ProcessUsageRow] = []
        rows.reserveCapacity(merged.count)
        for item in merged {
            let identity = identityByKey[item.key]
            let name = (identity?.name).flatMap { $0.isEmpty ? nil : $0 }
                ?? (item.key as NSString).lastPathComponent
            rows.append(ProcessUsageRow(
                id: item.key,
                name: name,
                icon: identity?.icon,
                cpu: item.cpu,
                memory: item.memory,
                memoryPercent: total > 0 ? min(Double(item.memory) / Double(total) * 100, 100) : 0,
                processCount: item.processCount,
                pids: item.pids
            ))
        }

        // 只保留有占用的一批：CPU 前 60 与内存前 60 的并集，
        // 否则「空闲但常驻」的 300 个守护进程会把内存榜挤出可视范围。
        let byCPU = rows.sorted { $0.cpu > $1.cpu }.prefix(60)
        let byMemory = rows.sorted { $0.memory > $1.memory }.prefix(60)
        var seen = Set<String>()
        var trimmed: [ProcessUsageRow] = []
        for row in byCPU + byMemory where seen.insert(row.id).inserted {
            trimmed.append(row)
        }
        processRows = trimmed
        processReady = true

        lastProcessAt = startedAt
        lastProcessTimes.removeAll(keepingCapacity: true)
        for sample in samples { lastProcessTimes[sample.pid] = sample.cpuTime }

        // 每分钟清一次已退出进程的缓存，避免长跑后字典膨胀
        processTicks += 1
        if processTicks >= 60 {
            processTicks = 0
            directory.prune(keeping: Set(samples.map(\.pid)))
        }
    }

    // MARK: - 关闭应用

    /// 行内「关闭」：对该应用聚合到的所有 pid 发 SIGTERM。
    ///
    /// 只做终止信号，不等待、不升级成 SIGKILL —— 目标是把吃资源的程序关掉，
    /// 让应用自己走正常退出流程（保存文档、清理临时文件）。
    /// 发出后立刻把该行从列表移除，下一拍采样若进程仍在会自己回来。
    @discardableResult
    func close(_ row: ProcessUsageRow) -> Int {
        let delivered = ProcessLoadProbe.terminate(pids: row.pids)
        if delivered > 0 {
            processRows.removeAll { $0.id == row.id }
        }
        return delivered
    }

    // MARK: - 演示数据

    /// 仅供界面验收（`--demo`）：注入确定性合成值并停表，
    /// 避免定时器在离屏渲染前把演示数据覆盖成真实值。
    func loadDemoData() {
        stop()
        cpuReady = true
        cpuPercent = 23
        breakdown = SystemLoadProbe.CPUBreakdown(user: 15, system: 8, idle: 77)

        var cpu = LoadHistory(capacity: cpuHistory.capacity)
        let slots = cpuHistory.capacity
        for index in 0..<slots {
            let phase = Double(index) / Double(max(slots - 1, 1))
            // 8%–38% 的缓慢波动，尾段抬升到 40% 出头，模拟一次编译
            let base = 12 + 10 * (sin(phase * .pi * 2.4 - 0.8) + 1) / 2
            let tail = phase > 0.78 ? (phase - 0.78) / 0.22 * 22 : 0
            cpu.append(base + tail)
        }
        cpuHistory = cpu

        let total: UInt64 = 17_179_869_184   // 16 GB
        let app: UInt64 = 6_871_947_674
        let wired: UInt64 = 3_221_225_472
        let compressed: UInt64 = 1_181_602_201
        let cached: UInt64 = 2_902_831_104
        let usage = SystemLoadProbe.MemoryUsage(total: total,
                                                used: app + wired + compressed,
                                                app: app,
                                                wired: wired,
                                                compressed: compressed,
                                                cached: cached)
        memory = usage

        var memoryHistory = LoadHistory(capacity: memoryHistory.capacity)
        for index in 0..<slots {
            let phase = Double(index) / Double(max(slots - 1, 1))
            memoryHistory.append(64 + 3.2 * phase + 1.1 * sin(phase * .pi * 3))
        }
        self.memoryHistory = memoryHistory

        // 进程列表：同样用合成数据，真实机器「谁在吃 CPU」属于不该出现在截图里的信息
        func icon(_ path: String) -> NSImage? {
            FileManager.default.fileExists(atPath: path)
                ? NSWorkspace.shared.icon(forFile: path)
                : nil
        }
        let demos: [(String, String, Double, UInt64, Int)] = [
            ("Safari", "/Applications/Safari.app", 46.2, 2_402_000_000, 6),
            ("Xcode", "/Applications/Xcode.app", 38.5, 3_611_000_000, 11),
            ("Claude", "/Applications/Claude.app", 22.8, 1_284_000_000, 3),
            ("微信", "/Applications/WeChat.app", 12.4, 908_000_000, 4),
            ("百度网盘", "/Applications/BaiduNetdisk_mac.app", 9.6, 612_000_000, 3),
            ("WindowServer", "", 8.1, 1_042_000_000, 1),
            ("mds_stores", "", 3.4, 188_000_000, 1),
            ("NetScope", "/Applications/NetScope.app", 1.9, 96_000_000, 2),
            ("Spotlight", "", 0.8, 74_000_000, 1),
            ("com.apple.WebKit.GPU", "", 0.6, 246_000_000, 1),
            ("coreaudiod", "", 0.4, 32_000_000, 1),
            ("launchd", "", 0.2, 18_000_000, 1)
        ]
        processRows = demos.map { name, path, cpu, mem, count in
            ProcessUsageRow(id: name, name: name, icon: path.isEmpty ? nil : icon(path),
                            cpu: cpu, memory: mem,
                            memoryPercent: Double(mem) / Double(total) * 100,
                            processCount: count, pids: [])
        }
        processReady = true

        // 系统功能区块的合成值：93% 磁盘、正常散热、开机 3 小时 12 分
        let totalDisk: UInt64 = 494_000_000_000
        stats = SystemStats(diskTotal: totalDisk,
                            diskFree: 34_600_000_000,
                            diskUsedFraction: 0.93,
                            thermal: "正常",
                            uptime: 3 * 3600 + 12 * 60)
    }
}
