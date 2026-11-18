import Darwin
import Foundation

/// 系统级 CPU / 内存采样。纯 syscall、不持有状态，便于无界面自检直接调用。
///
/// 为什么不用 `top` / `vm_stat` 子进程：解析文本既慢又依赖输出格式（系统版本间会变），
/// 而且本机实测沙箱环境下 `top` 直接返回 operation not permitted。
/// `host_statistics` 是活动监视器自己用的同一套 Mach 接口，开销在微秒级。
public enum SystemLoadProbe {

    // MARK: - CPU

    /// CPU 累计节拍（自开机以来）。
    ///
    /// 单位不是秒：实测每核每秒增长约 100 个节拍（10 核机器合计约 1000/秒），
    /// 因此 32 位计数器在 10 核机器上约 **49.7 天**回绕一次。差分必须按 32 位回绕处理，
    /// 否则长开机时长的机器会算出负增长、CPU 占用变成 0。
    public struct CPUTicks: Equatable {
        public var user: UInt64
        public var system: UInt64
        public var nice: UInt64
        public var idle: UInt64

        public var total: UInt64 { user + system + nice + idle }
        public var busy: UInt64 { user + system + nice }
    }

    public static func cpuTicks() -> CPUTicks? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        // cpu_ticks 元组顺序：0=user, 1=system, 2=idle, 3=nice
        return CPUTicks(user: UInt64(info.cpu_ticks.0),
                        system: UInt64(info.cpu_ticks.1),
                        nice: UInt64(info.cpu_ticks.3),
                        idle: UInt64(info.cpu_ticks.2))
    }

    /// 32 位计数器差分，处理一次回绕。
    public static func delta(_ previous: UInt64, _ current: UInt64) -> UInt64 {
        if current >= previous { return current - previous }
        return (UInt64(UInt32.max) + 1 - previous) + current
    }

    /// 两次累计节拍之间的系统级占用率（0–100，全核平均）。样本间隔为 0 时返回 nil。
    public static func cpuPercent(previous: CPUTicks, current: CPUTicks) -> Double? {
        let user = delta(previous.user, current.user)
        let system = delta(previous.system, current.system)
        let nice = delta(previous.nice, current.nice)
        let idle = delta(previous.idle, current.idle)
        let total = user + system + nice + idle
        guard total > 0 else { return nil }
        let busy = user + system + nice
        return min(max(Double(busy) / Double(total) * 100, 0), 100)
    }

    /// 占用率的三段拆解（0–100，三者相加为 100）。
    /// 详情面板要回答「这 23% 花在哪」——只有总量是看不出是在编译还是在等 IO 的。
    public struct CPUBreakdown: Equatable {
        /// 用户态（含 nice 调整过优先级的进程）
        public var user: Double
        /// 内核态（系统调用、驱动、中断）
        public var system: Double
        public var idle: Double
    }

    public static func cpuBreakdown(previous: CPUTicks, current: CPUTicks) -> CPUBreakdown? {
        let user = delta(previous.user, current.user) + delta(previous.nice, current.nice)
        let system = delta(previous.system, current.system)
        let idle = delta(previous.idle, current.idle)
        let total = user + system + idle
        guard total > 0 else { return nil }
        let sum = Double(total)
        return CPUBreakdown(user: Double(user) / sum * 100,
                            system: Double(system) / sum * 100,
                            idle: Double(idle) / sum * 100)
    }

    // MARK: - 内存

    /// 内存占用。口径对齐活动监视器的「已使用内存」：
    /// 应用内存（internal 减去可清除）+ 联动内存（wired）+ 压缩内存（compressor），
    /// 不含文件缓存（cached），因此不会因为系统拿空闲内存做缓存而虚高。
    ///
    /// 实测 16 GB 机器上各项之和（active/inactive/wired/compressor/free）
    /// 与物理内存基本闭合，说明 compressor 没有被重复计入 wired。
    public struct MemoryUsage: Equatable {
        public var total: UInt64
        public var used: UInt64
        public var app: UInt64
        public var wired: UInt64
        public var compressed: UInt64
        /// 文件缓存（external + purgeable），只用于提示，不计入 used
        public var cached: UInt64

        public var percent: Double {
            guard total > 0 else { return 0 }
            return min(max(Double(used) / Double(total) * 100, 0), 100)
        }
    }

    public static func memory() -> MemoryUsage? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let page = UInt64(vm_kernel_page_size)
        let internalPages = UInt64(stats.internal_page_count)
        let purgeablePages = UInt64(stats.purgeable_count)
        // internal 少于 purgeable 理论上不会出现，但计数器非原子读取时可能瞬时倒挂
        let appPages = internalPages > purgeablePages ? internalPages - purgeablePages : 0

        let app = appPages * page
        let wired = UInt64(stats.wire_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page
        let cached = (UInt64(stats.external_page_count) + purgeablePages) * page
        let total = ProcessInfo.processInfo.physicalMemory

        return MemoryUsage(total: total,
                           used: min(app + wired + compressed, total),
                           app: app,
                           wired: wired,
                           compressed: compressed,
                           cached: cached)
    }
}

/// 百分比历史（0–100 固定量纲）。与网络曲线不同，这里**不做峰值归一化**：
/// 5% 的 CPU 画满整高会让人误以为机器很忙，必须按绝对刻度呈现。
public struct LoadHistory: Equatable {
    public let capacity: Int
    public private(set) var points: [Double] = []

    public init(capacity: Int) {
        self.capacity = max(capacity, 2)
    }

    public mutating func append(_ value: Double) {
        points.append(min(max(value, 0), 100))
        if points.count > capacity {
            points.removeFirst(points.count - capacity)
        }
    }

    public mutating func clear() {
        points.removeAll(keepingCapacity: true)
    }

    public var latest: Double? { points.last }
    public var peak: Double { points.max() ?? 0 }

    public var average: Double? {
        guard !points.isEmpty else { return nil }
        return points.reduce(0, +) / Double(points.count)
    }
}
