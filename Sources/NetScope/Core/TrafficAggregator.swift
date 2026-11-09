import Foundation

/// 单个进程在一个采样周期内的增量与速率。
public struct ProcessDelta: Equatable, Sendable {
    public let pid: Int32
    public let rawName: String
    /// 本周期平均速率（字节/秒）
    public let downPerSecond: Double
    public let upPerSecond: Double
    /// 进程自启动以来的累计值
    public let totalIn: UInt64
    public let totalOut: UInt64
    public let deltaIn: UInt64
    public let deltaOut: UInt64
    /// 首个样本或累计值回退（pid 复用）时为 true，此时速率按 0 处理
    public let isBaseline: Bool
}

public struct BatchDelta: Equatable, Sendable {
    public let processes: [ProcessDelta]
    /// 与上一批之间的真实间隔（秒）
    public let interval: Double
    public let totalInPerSecond: Double
    public let totalOutPerSecond: Double
    public let totalInDelta: UInt64
    public let totalOutDelta: UInt64
}

/// 把 nettop 的累计值序列转成速率序列。
///
/// nettop 给出的是**进程自启动以来的累计字节**，所以速率必须靠两次采样差分得到。
/// 关键设计取舍：
///
/// 1. **进程短暂消失不清基准**。nettop 只列出当前持有 socket 的进程，一个进程可能这秒
///    有连接、下秒没有。若一消失就丢弃基准，它再次出现时会被当成新进程、速率归零，
///    那些字节就凭空消失了。这里改为保留基准 30 秒，重新出现时照常差分 ——
///    总量守恒，代价是那一次采样的瞬时速率略偏高（用该 pid 的真实时间差摊平）。
/// 2. **pid 复用靠累计值回退识别**。macOS 的 pid 会被回收复用，新进程的累计值必定
///    小于旧基准，据此判定基准过期，避免把「另一个进程」的流量算到同一个 key 上。
public struct TrafficAggregator {
    private struct Baseline {
        var name: String
        var inBytes: UInt64
        var outBytes: UInt64
        var lastSeen: TimeInterval
    }

    private var baselines: [Int32: Baseline] = [:]
    private var lastBatchTime: TimeInterval?
    public private(set) var batchCount = 0

    /// 基准保留时长：超过这个时间没再出现的进程，其基准会被清除。
    public var baselineTTL: TimeInterval = 30

    public init() {}

    public mutating func ingest(_ batch: [RawCounters], at timestamp: TimeInterval) -> BatchDelta {
        let globalInterval: Double
        if let last = lastBatchTime {
            globalInterval = max(timestamp - last, 0.001)
        } else {
            globalInterval = 1.0
        }
        lastBatchTime = timestamp
        batchCount += 1

        var deltas: [ProcessDelta] = []
        deltas.reserveCapacity(batch.count)
        var sumIn: UInt64 = 0
        var sumOut: UInt64 = 0

        for row in batch {
            if let base = baselines[row.pid],
               base.inBytes <= row.bytesIn,
               base.outBytes <= row.bytesOut,
               timestamp - base.lastSeen <= baselineTTL {
                let dIn = row.bytesIn - base.inBytes
                let dOut = row.bytesOut - base.outBytes
                let elapsed = max(timestamp - base.lastSeen, 0.05)
                sumIn += dIn
                sumOut += dOut
                deltas.append(ProcessDelta(
                    pid: row.pid,
                    rawName: row.rawName,
                    downPerSecond: Double(dIn) / elapsed,
                    upPerSecond: Double(dOut) / elapsed,
                    totalIn: row.bytesIn,
                    totalOut: row.bytesOut,
                    deltaIn: dIn,
                    deltaOut: dOut,
                    isBaseline: false
                ))
                baselines[row.pid] = Baseline(
                    name: row.rawName,
                    inBytes: row.bytesIn,
                    outBytes: row.bytesOut,
                    lastSeen: timestamp
                )
            } else {
                // 首次见到，或累计值回退（pid 被复用）
                baselines[row.pid] = Baseline(
                    name: row.rawName,
                    inBytes: row.bytesIn,
                    outBytes: row.bytesOut,
                    lastSeen: timestamp
                )
                deltas.append(ProcessDelta(
                    pid: row.pid,
                    rawName: row.rawName,
                    downPerSecond: 0,
                    upPerSecond: 0,
                    totalIn: row.bytesIn,
                    totalOut: row.bytesOut,
                    deltaIn: 0,
                    deltaOut: 0,
                    isBaseline: true
                ))
            }
        }

        // 清理长期未出现的基准
        if !baselines.isEmpty {
            let cutoff = timestamp - baselineTTL
            baselines = baselines.filter { $0.value.lastSeen >= cutoff }
        }

        return BatchDelta(
            processes: deltas,
            interval: globalInterval,
            totalInPerSecond: Double(sumIn) / globalInterval,
            totalOutPerSecond: Double(sumOut) / globalInterval,
            totalInDelta: sumIn,
            totalOutDelta: sumOut
        )
    }

    public mutating func reset() {
        baselines.removeAll(keepingCapacity: true)
        lastBatchTime = nil
        batchCount = 0
    }
}

/// 应用级聚合结果。
public struct AppTotal: Identifiable, Equatable, Sendable {
    public let id: String
    public var downPerSecond: Double
    public var upPerSecond: Double
    public var deltaIn: UInt64
    public var deltaOut: UInt64
    public var pids: [Int32]
    public var representativePID: Int32
}

public enum AppAggregation {
    /// 按调用方给出的 key 分组。key 的产生方式（bundle id / 可执行路径 / 进程名）
    /// 由上层决定，这里只管合并与排序，便于脱离 AppKit 单独测试。
    public static func merge(_ deltas: [ProcessDelta], keyFor: (ProcessDelta) -> String) -> [AppTotal] {
        var table: [String: AppTotal] = [:]
        for delta in deltas {
            // 基线样本没有增量，但要让应用出现在列表里（显示 0 速率）
            let key = keyFor(delta)
            if var existing = table[key] {
                existing.downPerSecond += delta.downPerSecond
                existing.upPerSecond += delta.upPerSecond
                existing.deltaIn += delta.deltaIn
                existing.deltaOut += delta.deltaOut
                existing.pids.append(delta.pid)
                table[key] = existing
            } else {
                table[key] = AppTotal(
                    id: key,
                    downPerSecond: delta.downPerSecond,
                    upPerSecond: delta.upPerSecond,
                    deltaIn: delta.deltaIn,
                    deltaOut: delta.deltaOut,
                    pids: [delta.pid],
                    representativePID: delta.pid
                )
            }
        }
        return table.values.sorted { lhs, rhs in
            let l = lhs.downPerSecond + lhs.upPerSecond
            let r = rhs.downPerSecond + rhs.upPerSecond
            if l == r { return lhs.id < rhs.id }
            return l > r
        }
    }
}

/// 速率历史，供迷你折线图使用。
public struct RateHistory: Equatable, Sendable {
    public struct Point: Equatable, Sendable {
        public let down: Double
        public let up: Double
    }

    public private(set) var points: [Point] = []
    public let capacity: Int

    public init(capacity: Int = 60) {
        self.capacity = capacity
    }

    public mutating func append(down: Double, up: Double) {
        points.append(Point(down: down, up: up))
        if points.count > capacity {
            points.removeFirst(points.count - capacity)
        }
    }

    public mutating func clear() {
        points.removeAll(keepingCapacity: true)
    }

    /// 归一化到 0...1 的峰值，用于画图。空数据时返回 1 避免除零。
    public var peak: Double {
        let maximum = points.reduce(0.0) { Swift.max($0, Swift.max($1.down, $1.up)) }
        return maximum > 0 ? maximum : 1
    }

    public mutating func seed(_ newPoints: [Point]) {
        points = Array(newPoints.suffix(capacity))
    }
}
