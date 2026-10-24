// 同时采样 external / physical 两条通道，逐批对比增量。
// 用于验证「物理接口是全接口子集」这个 VPN 去重的前提是否成立。
//
// 用法：bash Scripts/traffic-probe.sh [秒数]

import Foundation

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T
    init(_ value: T) { storage = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
    func mutate(_ body: (inout T) -> Void) {
        lock.lock(); body(&storage); lock.unlock()
    }
}

let duration = CommandLine.arguments.count > 1 ? (Double(CommandLine.arguments[1]) ?? 8) : 8

let externalSampler = NettopPTY()
let physicalSampler = NettopPTY()
let externalBatches = Box<[[RawCounters]]>([])
let physicalBatches = Box<[[RawCounters]]>([])
let failures = Box<[String]>([])

externalSampler.start(interval: 1, scope: .external) { batch in
    externalBatches.mutate { $0.append(batch) }
} onFailure: { reason in
    failures.mutate { $0.append("external: \(reason)") }
}

physicalSampler.start(interval: 1, scope: .physical) { batch in
    physicalBatches.mutate { $0.append(batch) }
} onFailure: { reason in
    failures.mutate { $0.append("physical: \(reason)") }
}

let deadline = Date().addingTimeInterval(duration)
while Date() < deadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
}
externalSampler.stop()
physicalSampler.stop()

/// 逐批差分，返回每批的 (入, 出)
func deltas(_ batches: [[RawCounters]]) -> [(UInt64, UInt64)] {
    var result: [(UInt64, UInt64)] = []
    for (index, batch) in batches.enumerated() where index > 0 {
        let previous = batches[index - 1]
        var sumIn: UInt64 = 0
        var sumOut: UInt64 = 0
        for row in batch {
            guard let old = previous.first(where: { $0.pid == row.pid }),
                  old.bytesIn <= row.bytesIn, old.bytesOut <= row.bytesOut else { continue }
            sumIn &+= row.bytesIn - old.bytesIn
            sumOut &+= row.bytesOut - old.bytesOut
        }
        result.append((sumIn, sumOut))
    }
    return result
}

let ed = deltas(externalBatches.value)
let pd = deltas(physicalBatches.value)

print("批次数: external \(externalBatches.value.count) / physical \(physicalBatches.value.count)")
if !failures.value.isEmpty { print("失败: \(failures.value.joined(separator: "; "))") }

// 两条通道的批次数量可能不同（启动耗时、偶发丢批），只比较双方都有的批次。
// 之前按 max 对齐会让"只有一侧有数据"的那一行显示成 0 与正值之差，看起来像"physical 反超"。
let comparable = min(ed.count, pd.count)
print("可比批次: \(comparable)")
print("批次   external total   physical total   差值(虚拟接口)  进程数")
for index in 0..<comparable {
    let e = ed[index].0 + ed[index].1
    let p = pd[index].0 + pd[index].1
    let counts = index + 1 < externalBatches.value.count ? externalBatches.value[index + 1].count : 0
    print(String(format: "%4d   %14llu   %14llu   %14lld   %4d",
                 index + 1, e, p, Int64(e) - Int64(p), counts))
}

let eTotal = ed.prefix(comparable).reduce(UInt64(0)) { $0 &+ $1.0 &+ $1.1 }
let pTotal = pd.prefix(comparable).reduce(UInt64(0)) { $0 &+ $1.0 &+ $1.1 }
print("合计: external=\(eTotal)  physical=\(pTotal)  虚拟接口部分=\(Int64(eTotal) - Int64(pTotal))")
print(eTotal == 0 ? "无流量，无法判断" :
      (pTotal <= eTotal ? "✓ 物理接口是全接口的子集" : "✗ 反了：physical 大于 external"))
