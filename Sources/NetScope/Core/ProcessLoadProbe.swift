import Darwin
import Foundation

/// 单个进程的一次采样快照。
public struct ProcessLoadSample: Equatable, Sendable {
    public let pid: Int32
    /// `proc_name` 的短名（可能为空：少数系统进程不允许读取）
    public let name: String
    /// 累计 CPU 时间（用户态 + 内核态，纳秒）
    public let cpuTime: UInt64
    /// 物理内存占用（`ri_phys_footprint`，与活动监视器「内存」列同口径）
    public let footprint: UInt64

    public init(pid: Int32, name: String, cpuTime: UInt64, footprint: UInt64) {
        self.pid = pid
        self.name = name
        self.cpuTime = cpuTime
        self.footprint = footprint
    }
}

/// 进程级 CPU / 内存采样。
///
/// 为什么不用 `ps`：`ps -o %cpu` 给的是「自进程启动以来的平均占用」
/// （cputime / etime），不是当前瞬时值 —— 长时间运行的浏览器会永远显示 0.3%。
/// 活动监视器用的就是 `proc_pid_rusage` 的累计时间做差分，这里走同一条路：
/// 每次采样只取累计值，占用率由 `cpuPercents` 用两次快照相减得到。
///
/// 实测 528 个进程一次全量快照约 10 ms，放在后台队列里做，不占主线程。
public enum ProcessLoadProbe {

    /// `ri_user_time` / `ri_system_time` 的单位是 **mach 绝对时间节拍**，不是纳秒。
    /// 实测 Apple Silicon 的 timebase 是 125/3：1 秒忙等只报 0.023（若按纳秒解读），
    /// 换算后是 0.94 —— 差了约 41 倍。不除 timebase 的话所有进程占用都会小两个数量级。
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    private static func nanoseconds(_ ticks: UInt64) -> UInt64 {
        // ticks × 125 溢出需要 1.48×10¹⁷ 个节拍 ≈ 195 年（24 MHz 节拍），进程级远不会到
        ticks * UInt64(timebase.numer) / UInt64(timebase.denom)
    }

    /// 全量快照。读不到 rusage 的进程直接跳过（部分系统进程即使同 uid 也会拒绝）。
    public static func snapshot() -> [ProcessLoadSample] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        // 两次调用之间进程数会变，多留 64 个位置
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let count = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listallpids(buffer.baseAddress,
                             Int32(buffer.count * MemoryLayout<pid_t>.stride))
        }
        guard count > 0 else { return [] }

        var samples: [ProcessLoadSample] = []
        samples.reserveCapacity(Int(count))
        for index in 0..<Int(count) {
            let pid = pids[index]
            guard pid > 0 else { continue }        // 0 是 kernel_task，没有用户态时间
            guard let info = rusage(pid: pid) else { continue }
            let cpuTime = nanoseconds(info.ri_user_time &+ info.ri_system_time)
            samples.append(ProcessLoadSample(pid: pid,
                                             name: name(pid: pid),
                                             cpuTime: cpuTime,
                                             footprint: info.ri_phys_footprint))
        }
        return samples
    }

    private static func rusage(pid: Int32) -> rusage_info_v4? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
            }
        }
        return result == 0 ? info : nil
    }

    private static func name(pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return "" }
        return String(cString: buffer)
    }

    /// 两次快照相减得到每个进程的瞬时占用率。
    ///
    /// 单位是「单核百分比」——与活动监视器一致：一个进程跑满一个核是 100%，
    /// 跑满 10 个核是 1000%。`elapsed` 用采样起点的墙钟差，而不是各进程自己的
    /// 启动时间（后者拿不到，也没必要）。
    public static func cpuPercents(previous: [Int32: UInt64],
                                   current: [ProcessLoadSample],
                                   elapsed: TimeInterval) -> [Int32: Double] {
        guard elapsed > 0 else { return [:] }
        var result: [Int32: Double] = [:]
        result.reserveCapacity(current.count)
        for sample in current {
            guard let before = previous[sample.pid] else { continue }
            // 进程重启会复用 pid，但累计时间只会倒退；这种情况当作无数据，别算出负数
            guard sample.cpuTime >= before else { continue }
            let seconds = Double(sample.cpuTime - before) / 1_000_000_000
            result[sample.pid] = seconds / elapsed * 100
        }
        return result
    }

    /// 把 pid 级占用合并成「应用」级。
    ///
    /// 同一个应用的多个 Helper 合成一条，与网络列表的聚合口径一致
    /// （否则 Chrome 会占满前十行）。`group` 由调用方提供，因为
    /// 「pid → 应用」需要 `ProcessDirectory` 的 bundle 反查能力。
    public static func merge(_ samples: [ProcessLoadSample],
                             percent: [Int32: Double],
                             group: (Int32, String) -> String) -> [MergedLoad] {
        var byKey: [String: MergedLoad] = [:]
        for sample in samples {
            let key = group(sample.pid, sample.name)
            var entry = byKey[key] ?? MergedLoad(key: key, cpu: 0, memory: 0, processCount: 0)
            entry.cpu += percent[sample.pid] ?? 0
            entry.memory &+= sample.footprint
            entry.processCount += 1
            entry.pids.append(sample.pid)
            byKey[key] = entry
        }
        return byKey.values.filter { $0.cpu > 0.01 || $0.memory > 0 }
    }

    /// 关掉一组进程（「关闭」按钮）。
    ///
    /// 先发 SIGTERM 让应用自己走正常退出（保存文档、清理临时文件），
    /// 不做 SIGKILL：这里的目标是「关掉吃资源的程序」，不是强杀。
    /// 返回成功发出的信号个数。
    @discardableResult
    public static func terminate(pids: [Int32]) -> Int {
        var delivered = 0
        for pid in Set(pids) where pid > 1 {
            if kill(pid, SIGTERM) == 0 { delivered += 1 }
        }
        return delivered
    }

    public struct MergedLoad: Equatable, Sendable {
        public var key: String
        public var cpu: Double
        public var memory: UInt64
        public var processCount: Int
        /// 参与聚合的 pid，供「关闭」使用
        public var pids: [Int32]

        public init(key: String, cpu: Double, memory: UInt64, processCount: Int, pids: [Int32] = []) {
            self.key = key
            self.cpu = cpu
            self.memory = memory
            self.processCount = processCount
            self.pids = pids
        }
    }
}
