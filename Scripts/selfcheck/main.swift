import Foundation

// NetScope 无界面自检：验证 CSV 解析、累计值差分、应用聚合、格式化，
// 并用真实 pty 采样跑一轮端到端（不依赖 GUI）。
//
// 编译：见 Scripts/selfcheck/run.sh

var failures: [String] = []
var passes = 0

func expect(_ condition: Bool, _ label: String, detail: @autoclosure () -> String = "") {
    if condition {
        passes += 1
        print("  ✓ \(label)")
    } else {
        let extra = detail()
        let suffix = extra.isEmpty ? "" : " — \(extra)"
        failures.append(label + suffix)
        print("  ✗ \(label)\(suffix)")
    }
}

func section(_ title: String) {
    print("\n\(title)")
}

// MARK: - CSV 解析

section("1. nettop CSV 解析")
do {
    let header = ",bytes_in,bytes_out,"
    expect(NettopCSV.isHeader(header), "识别表头")
    expect(NettopCSV.parse(header) == nil, "表头不当作数据行")

    let simple = NettopCSV.parse("apsd.172,5564,14301,")
    expect(simple?.pid == 172, "解析 pid", detail: "\(String(describing: simple?.pid))")
    expect(simple?.rawName == "apsd", "解析进程名")
    expect(simple?.bytesIn == 5564, "解析入站字节")
    expect(simple?.bytesOut == 14301, "解析出站字节")

    // 进程名含点：pid 必须从最后一个点后取
    let dotted = NettopCSV.parse("com.apple.WebKit.WebContent.1234,999,888,")
    expect(dotted?.pid == 1234, "含点进程名的 pid", detail: "\(String(describing: dotted?.pid))")
    expect(dotted?.rawName == "com.apple.WebKit.WebContent", "含点进程名的名字")

    // 真实环境里会出现的截断名（含空格与中文）
    let truncated = NettopCSV.parse("哔哩哔哩 He.32520,237491316,10979,")
    expect(truncated?.pid == 32520, "截断中文名解析")
    expect(truncated?.bytesIn == 237_491_316, "大数值解析")

    // 行尾 \r\n（pty 未关 OPOST 时会出现）
    expect(NettopCSV.parse("apsd.172,10,20,\r")?.bytesOut == 20, "容忍 CRLF 行尾")

    // 畸形输入
    expect(NettopCSV.parse("") == nil, "空行忽略")
    expect(NettopCSV.parse("garbage line") == nil, "非 CSV 行忽略")
    expect(NettopCSV.parse("nodot,1,2,") == nil, "缺少 .pid 忽略")
    expect(NettopCSV.parse("name.0,1,2,") == nil, "pid 为 0 忽略")
    expect(NettopCSV.parse("name.abc,1,2,") == nil, "pid 非数字忽略")
    expect(NettopCSV.parse("name.9,abc,2,") == nil, "字节数非数字忽略")
}

section("2. 字节流按行切分")
do {
    var buffer = Data("alpha\nbeta\npartial".utf8)
    let first = NettopCSV.splitLines(&buffer)
    expect(first == ["alpha", "beta"], "切出完整行", detail: "\(first)")
    expect(String(data: buffer, encoding: .utf8) == "partial", "保留不完整尾部")

    buffer = Data("x\r\n".utf8)
    expect(NettopCSV.splitLines(&buffer) == ["x\r"], "CRLF 切成一行（\\r 由 parse 裁掉）")

    buffer = Data()
    expect(NettopCSV.splitLines(&buffer).isEmpty, "空缓冲返回空")
}

// MARK: - 差分

section("3. 累计值差分")
do {
    var aggregator = TrafficAggregator()

    // 首批全部是基线
    let firstBatch = [
        RawCounters(pid: 100, rawName: "alpha", bytesIn: 1_000, bytesOut: 500),
        RawCounters(pid: 200, rawName: "beta", bytesIn: 2_000, bytesOut: 2_000)
    ]
    let first = aggregator.ingest(firstBatch, at: 100.0)
    expect(first.processes.allSatisfy { $0.isBaseline }, "首批全部标记为基线")
    expect(first.processes.allSatisfy { $0.downPerSecond == 0 }, "首批速率为 0")
    expect(first.totalInDelta == 0, "首批总增量为 0")

    // 第二批：alpha 入站 +3000 / 出站 +500，时间差 1 秒
    let secondBatch = [
        RawCounters(pid: 100, rawName: "alpha", bytesIn: 4_000, bytesOut: 1_000),
        RawCounters(pid: 200, rawName: "beta", bytesIn: 2_000, bytesOut: 2_000)
    ]
    let second = aggregator.ingest(secondBatch, at: 101.0)
    let alpha = second.processes.first { $0.pid == 100 }
    expect(alpha?.downPerSecond == 3_000, "alpha 下行速率 3000 B/s", detail: "\(String(describing: alpha?.downPerSecond))")
    expect(alpha?.upPerSecond == 500, "alpha 上行速率 500 B/s", detail: "\(String(describing: alpha?.upPerSecond))")
    let beta = second.processes.first { $0.pid == 200 }
    expect(beta?.downPerSecond == 0, "无流量进程速率为 0")
    expect(second.totalInDelta == 3_000, "总入站增量 3000", detail: "\(second.totalInDelta)")
    expect(abs(second.interval - 1.0) < 0.0001, "采样间隔为 1 秒")

    // 间隔 2 秒时速率应按真实时间摊平
    let third = aggregator.ingest([
        RawCounters(pid: 100, rawName: "alpha", bytesIn: 6_000, bytesOut: 1_000)
    ], at: 103.0)
    let alpha3 = third.processes.first { $0.pid == 100 }
    expect(alpha3?.downPerSecond == 1_000, "2 秒间隔摊平为 1000 B/s", detail: "\(String(describing: alpha3?.downPerSecond))")
}

section("4. pid 复用与进程消失")
do {
    var aggregator2 = TrafficAggregator()
    _ = aggregator2.ingest([RawCounters(pid: 500, rawName: "old", bytesIn: 9_000, bytesOut: 9_000)], at: 10.0)

    // 累计值回退 = pid 被新进程复用，必须当作基线而不是负增长
    let reused = aggregator2.ingest([RawCounters(pid: 500, rawName: "new", bytesIn: 100, bytesOut: 50)], at: 11.0)
    let row = reused.processes.first { $0.pid == 500 }
    expect(row?.isBaseline == true, "累计值回退识别为 pid 复用")
    expect(row?.downPerSecond == 0, "复用后速率为 0，不产生负增长")

    // 进程消失一批后再出现：基准仍在 TTL 内，应能继续差分
    var agg3 = TrafficAggregator()
    _ = agg3.ingest([RawCounters(pid: 700, rawName: "flaky", bytesIn: 0, bytesOut: 0)], at: 20.0)
    _ = agg3.ingest([], at: 21.0)   // 这一秒它没有 socket
    let backAgain = agg3.ingest([RawCounters(pid: 700, rawName: "flaky", bytesIn: 5_000, bytesOut: 0)], at: 23.0)
    let flaky = backAgain.processes.first { $0.pid == 700 }
    expect(flaky?.isBaseline == false, "消失后重现仍按既有基准差分")
    expect(flaky?.deltaIn == 5_000, "消失期间的流量不丢失", detail: "\(String(describing: flaky?.deltaIn))")
    expect((flaky?.downPerSecond ?? 0) <= 2_500 + 1, "按真实 2 秒时间差摊平", detail: "\(String(describing: flaky?.downPerSecond))")

    // 超过 TTL 的基准应被清理
    var agg4 = TrafficAggregator()
    agg4.baselineTTL = 5
    _ = agg4.ingest([RawCounters(pid: 800, rawName: "stale", bytesIn: 100, bytesOut: 0)], at: 0.0)
    let later = agg4.ingest([RawCounters(pid: 800, rawName: "stale", bytesIn: 200, bytesOut: 0)], at: 100.0)
    expect(later.processes.first?.isBaseline == true, "超过 TTL 的基准失效")
}

// MARK: - 聚合与历史

section("5. 应用级聚合")
do {
    let deltas = [
        ProcessDelta(pid: 1, rawName: "Safari", downPerSecond: 100, upPerSecond: 10, totalIn: 0, totalOut: 0, deltaIn: 100, deltaOut: 10, isBaseline: false),
        ProcessDelta(pid: 2, rawName: "WebContent", downPerSecond: 900, upPerSecond: 5, totalIn: 0, totalOut: 0, deltaIn: 900, deltaOut: 5, isBaseline: false),
        ProcessDelta(pid: 3, rawName: "Spotify", downPerSecond: 50, upPerSecond: 1, totalIn: 0, totalOut: 0, deltaIn: 50, deltaOut: 1, isBaseline: false)
    ]
    let merged = AppAggregation.merge(deltas) { delta in
        delta.pid == 1 || delta.pid == 2 ? "com.apple.Safari" : "com.spotify.client"
    }
    expect(merged.count == 2, "同 bundle 的多进程合并为一条", detail: "\(merged.count)")
    expect(merged.first?.id == "com.apple.Safari", "按总速率排序")
    expect(merged.first?.downPerSecond == 1_000, "合并后下行速率相加", detail: "\(String(describing: merged.first?.downPerSecond))")
    expect(merged.first?.pids.count == 2, "保留合并的 pid 列表")
}

section("6. 速率历史")
do {
    var history = RateHistory(capacity: 3)
    for index in 0..<5 {
        history.append(down: Double(index), up: 0)
    }
    expect(history.points.count == 3, "容量裁剪", detail: "\(history.points.count)")
    expect(history.points.first?.down == 2, "保留最新样本")
    expect(history.peak == 4, "峰值取自保留区间", detail: "\(history.peak)")
    history.clear()
    expect(history.peak == 1, "空历史峰值退化为 1，避免除零")
}

section("7. 格式化")
do {
    expect(ByteFormat.rate(0) == "0 B/s", "0 速率", detail: ByteFormat.rate(0))
    expect(ByteFormat.rate(999) == "999 B/s", "字节档", detail: ByteFormat.rate(999))
    expect(ByteFormat.rate(1_500) == "1.50 KB/s", "KB 档", detail: ByteFormat.rate(1_500))
    expect(ByteFormat.rate(1_240_000) == "1.24 MB/s", "MB 档", detail: ByteFormat.rate(1_240_000))
    expect(ByteFormat.size(0) == "0 B", "0 字节", detail: ByteFormat.size(0))
    expect(ByteFormat.compact(1_200_000) == "1.2M", "菜单栏紧凑格式", detail: ByteFormat.compact(1_200_000))
    expect(ByteFormat.compact(860_000) == "860K", "紧凑格式 K 档", detail: ByteFormat.compact(860_000))
    expect(ByteFormat.compact(0) == "0B", "紧凑格式 0", detail: ByteFormat.compact(0))
}

// MARK: - VPN 去重

section("8. VPN 隧道检测")
do {
    expect(TunnelDetector.isTunnelClient("FlClashCore"), "识别 FlClashCore")
    expect(TunnelDetector.isTunnelClient("io.tailscale.ipn.macsys.network-extension"), "识别 Tailscale 扩展")
    expect(TunnelDetector.isTunnelClient("Stash"), "识别 Stash")
    expect(TunnelDetector.isTunnelClient("sing-box"), "识别 sing-box")
    expect(TunnelDetector.isTunnelClient("CloudflareWARP"), "识别 WARP")
    expect(!TunnelDetector.isTunnelClient(""), "空名不误判")
    expect(!TunnelDetector.isTunnelClient("Safari"), "Safari 不是隧道客户端")
    expect(!TunnelDetector.isTunnelClient("Google Chrome"), "Chrome 不是隧道客户端")
    expect(!TunnelDetector.isTunnelClient("com.apple.WebKit.WebContent"), "WebContent 不是隧道客户端")
    expect(!TunnelDetector.isTunnelClient("mDNSResponder"), "mDNSResponder 不是隧道客户端")

    let tunnels = TunnelDetector.activeTunnelNames()
    expect(tunnels.allSatisfy { $0.hasPrefix("utun") }, "隧道接口均为 utun 前缀", detail: "\(tunnels)")
    expect(Set(tunnels).count == tunnels.count, "隧道列表无重复")
    expect(TunnelDetector.hasActiveTunnel() == !tunnels.isEmpty, "hasActiveTunnel 与列表一致")
    print("    当前活动隧道：\(tunnels.isEmpty ? "无" : tunnels.joined(separator: ", "))")
}

section("9. 接口范围参数")
do {
    expect(InterfaceScope.external.nettopArguments == ["-t", "external"], "external 传 -t external")
    expect(InterfaceScope.physical.nettopArguments == ["-t", "wifi", "-t", "wired"], "physical 只传 wifi + wired")
}

// MARK: - 历史持久化

section("10. 历史持久化（临时数据库）")
do {
    let path = NSTemporaryDirectory() + "netscope-selfcheck-\(UUID().uuidString).db"
    defer { try? FileManager.default.removeItem(atPath: path) }

    guard let store = HistoryStore(path: path) else {
        expect(false, "打开测试数据库")
        exit(1)
    }
    expect(true, "打开测试数据库")

    let today = HistoryStore.dayString(for: Date())

    store.record([
        .init(key: "/Applications/Safari.app", name: "Safari", bytesIn: 1_000, bytesOut: 500),
        .init(key: "/Applications/WeChat.app", name: "微信", bytesIn: 200, bytesOut: 100)
    ])
    // 同一应用的第二批要累加，而不是覆盖
    store.record([
        .init(key: "/Applications/Safari.app", name: "Safari", bytesIn: 500, bytesOut: 250)
    ])
    store.flush(force: true)

    let dayTotal = store.total(days: 1)
    // total 是全部应用的合计：Safari 1500 + 微信 200
expect(dayTotal.bytesIn == 1_700, "同一天的增量累加", detail: "\(dayTotal.bytesIn)")
    expect(dayTotal.bytesOut == 850, "出站增量累加", detail: "\(dayTotal.bytesOut)")

    let top = store.topApps(limit: 5)
    expect(top.count == 2, "按应用聚合为 2 条", detail: "\(top.count)")
    expect(top.first?.name == "Safari", "按总量降序")
    expect(top.first?.total == 2_250, "Safari 合计 2250", detail: "\(top.first?.total ?? 0)")

    let series = store.dailyTotals(days: 7)
    expect(series.count == 7, "7 天序列长度", detail: "\(series.count)")
    expect(series.last?.day == today, "最后一个元素是今天")
    expect(series.last?.total == 2_550, "今天合计 1700+850")
    expect(series.first?.total == 0, "无记录的日期补 0")

    // 跨天
    let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
    store.record([.init(key: "/Applications/Safari.app", name: "Safari", bytesIn: 9_000, bytesOut: 0)],
                 at: yesterday)
    store.flush(force: true)
    expect(store.total(days: 7).bytesIn == 10_700, "7 天合计含昨天", detail: "\(store.total(days: 7).bytesIn)")
    expect(store.total(days: 1).bytesIn == 1_700, "今日合计不含昨天")

    expect(HistoryStore.recentDays(3).count == 3, "recentDays 长度")
    expect(HistoryStore.recentDays(0).isEmpty, "recentDays(0) 为空")
    store.close()
}

// MARK: - 告警

section("11. 流量告警逻辑")
do {
    let center = AlertCenter()
    let fired = Box<[(String, Double)]>([])
    center.onAlert = { name, rate in fired.mutate { $0.append((name, rate)) } }
    let threshold = 5_000_000.0     // 5 MB/s

    center.evaluate([.init(key: "a", name: "A", rate: 4_000_000)], threshold: threshold)
    expect(fired.value.isEmpty, "低于阈值不告警")

    center.evaluate([.init(key: "b", name: "Chrome", rate: 9_000_000)], threshold: threshold)
    center.evaluate([.init(key: "b", name: "Chrome", rate: 9_000_000)], threshold: threshold)
    expect(fired.value.isEmpty, "连续 2 次还不够")

    center.evaluate([.init(key: "b", name: "Chrome", rate: 9_000_000)], threshold: threshold)
    expect(fired.value.count == 1, "连续 3 次触发一次", detail: "\(fired.value.count)")
    expect(fired.value.first?.0 == "Chrome", "告警对象正确")

    center.evaluate([.init(key: "b", name: "Chrome", rate: 9_000_000)], threshold: threshold)
    center.evaluate([.init(key: "b", name: "Chrome", rate: 9_000_000)], threshold: threshold)
    expect(fired.value.count == 1, "冷却期内不重复告警", detail: "\(fired.value.count)")

    // 掉到阈值以下要清零，否则"连续"会跨越很久
    center.evaluate([.init(key: "b", name: "Chrome", rate: 100)], threshold: threshold)
    center.evaluate([.init(key: "b", name: "Chrome", rate: 9_000_000)], threshold: threshold)
    center.evaluate([.init(key: "b", name: "Chrome", rate: 9_000_000)], threshold: threshold)
    expect(fired.value.count == 1, "计数清零后需重新累计", detail: "\(fired.value.count)")

    let disabled = Box<Int>(0)
    let off = AlertCenter()
    off.onAlert = { _, _ in disabled.mutate { $0 += 1 } }
    off.evaluate([.init(key: "c", name: "C", rate: 100_000_000)], threshold: 0)
    expect(disabled.value == 0, "阈值为 0 视为关闭")
}

// MARK: - 菜单栏趋势图

section("12. 菜单栏趋势图")
do {
    var emptyHistory = RateHistory(capacity: 60)
    let empty = MenuBarSparkline.image(history: emptyHistory)
    expect(empty.size == NSSize(width: 34, height: 18), "尺寸固定 34×18", detail: "\(empty.size)")
    expect(empty.isTemplate, "是 template image（自适应深浅色）")

    var history = RateHistory(capacity: 60)
    for index in 0..<20 { history.append(down: Double(index) * 1_000, up: 0) }
    let drawn = MenuBarSparkline.image(history: history)
    expect(drawn.size == empty.size, "尺寸不随数据变化")
    // 真正光栅化一次，确认绘制路径不会崩（创建 NSImage 时画布是惰性的）
    expect(drawn.tiffRepresentation != nil, "有数据时能光栅化")
    expect(empty.tiffRepresentation != nil, "空历史也能光栅化（画基线）")
}



// MARK: - 真实采样（pty 端到端）

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

/// 逐批差分，返回每批的 (入站, 出站) 增量
func sumDeltas(_ batches: [[RawCounters]]) -> [(UInt64, UInt64)] {
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

section("13. 真实 pty 采样（双通道并行）")
// 必须并行采样：串行跑（先 external 再 physical）时流量本身在波动，
// 实测出现过 physical 是 external 三倍的假象，会把正确实现判成错误。
let extSampler = NettopPTY()
let phySampler = NettopPTY()
let extBatches = Box<[[RawCounters]]>([])
let phyBatches = Box<[[RawCounters]]>([])
let extFailure = Box<String?>(nil)
let phyFailure = Box<String?>(nil)
let targetBatches = 4

extSampler.start(interval: 1, scope: .external) { batch in
    extBatches.mutate { if $0.count < targetBatches { $0.append(batch) } }
} onFailure: { reason in
    extFailure.value = reason
}
phySampler.start(interval: 1, scope: .physical) { batch in
    phyBatches.mutate { if $0.count < targetBatches { $0.append(batch) } }
} onFailure: { reason in
    phyFailure.value = reason
}

let deadline = Date().addingTimeInterval(20)
while Date() < deadline && (extBatches.value.count < 3 || phyBatches.value.count < 3) {
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
}
extSampler.stop()
phySampler.stop()

expect(extFailure.value == nil, "external 通道无失败", detail: extFailure.value ?? "")
expect(phyFailure.value == nil, "physical 通道无失败", detail: phyFailure.value ?? "")
expect(extBatches.value.count >= 2, "external 收到至少 2 批", detail: "实收 \(extBatches.value.count)")
expect(phyBatches.value.count >= 2, "physical 收到至少 2 批", detail: "实收 \(phyBatches.value.count)")

if let first = extBatches.value.first {
    expect(first.count >= 3, "首批包含多个进程", detail: "\(first.count) 个")
    expect(first.allSatisfy { $0.pid > 0 }, "全部条目 pid 合法")
    expect(first.allSatisfy { !$0.rawName.isEmpty }, "全部条目有进程名")
    let busiest = first.max { $0.bytesIn < $1.bytesIn }
    print("    首批进程数 \(first.count)，累计入站最大：\(busiest?.rawName ?? "-") \(ByteFormat.size(busiest?.bytesIn ?? 0))")
}

section("14. 物理接口是全接口的子集")
let extDeltas = sumDeltas(extBatches.value)
let phyDeltas = sumDeltas(phyBatches.value)
// 两条通道的批次数量可能不同（启动耗时、偶发丢批），只比较双方都有的批次
let comparable = min(extDeltas.count, phyDeltas.count)
expect(comparable >= 1, "存在可比批次", detail: "external \(extDeltas.count) / physical \(phyDeltas.count)")

if comparable >= 1 {
    let extTotal = extDeltas.prefix(comparable).reduce(UInt64(0)) { $0 &+ $1.0 &+ $1.1 }
    let phyTotal = phyDeltas.prefix(comparable).reduce(UInt64(0)) { $0 &+ $1.0 &+ $1.1 }
    let tunnelPart = Int64(extTotal) - Int64(phyTotal)
    print("    external=\(extTotal)  physical=\(phyTotal)  虚拟接口部分=\(tunnelPart)")

    expect(extDeltas.contains { $0.0 + $0.1 > 0 }, "至少一批存在真实流量增量")
    // 采样时刻相差几十毫秒，给 10% + 4KB 的容差；若这里反了说明 -t 语义变了，整个方案要重估
    expect(phyTotal <= extTotal + UInt64(Double(extTotal) * 0.1) + 4096,
           "物理接口增量不超过全接口增量",
           detail: "physical=\(phyTotal) external=\(extTotal)")

    // 累计值单调性：同一 pid 跨批次的累计值不应变小（变小只应是 pid 复用）
    let captured = extBatches.value
    if captured.count >= 2 {
        let pidSet = Set(captured[1].map(\.pid))
        let common = captured[0].filter { pidSet.contains($0.pid) }
        let decreases = common.filter { row in
            guard let later = captured[1].first(where: { $0.pid == row.pid }) else { return false }
            return later.bytesIn < row.bytesIn
        }
        expect(decreases.count <= 2, "累计值基本单调（允许少量 pid 复用）",
               detail: "回退 \(decreases.count) / 共同 \(common.count)")
    }
}


print("\n————————————————————————")
if failures.isEmpty {
    print("全部通过：\(passes) 项断言")
    exit(0)
} else {
    print("失败 \(failures.count) 项 / 通过 \(passes) 项")
    for item in failures {
        print("  - \(item)")
    }
    exit(1)
}
