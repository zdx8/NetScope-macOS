import Foundation
import AppKit

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

section("10. 分层时间桶持久化（临时数据库）")
do {
    let path = NSTemporaryDirectory() + "netscope-selfcheck-\(UUID().uuidString).db"
    defer { try? FileManager.default.removeItem(atPath: path) }

    guard let store = HistoryStore(path: path) else {
        expect(false, "打开测试数据库")
        exit(1)
    }
    expect(true, "打开测试数据库")

    // bucketStart 对齐：任意时刻向下取整到桶宽的整数倍（纯数学，与当前时间无关）
    let fixed = Date(timeIntervalSince1970: 1_764_000_137)   // 不落在任何桶边界上
    expect(HistoryStore.bucketStart(for: fixed, granularity: .fiveMinutes) == 1_764_000_000,
           "5 分钟桶取整", detail: "\(HistoryStore.bucketStart(for: fixed, granularity: .fiveMinutes))")
    expect(HistoryStore.bucketStart(for: fixed, granularity: .thirtyMinutes) == 1_764_000_000,
           "30 分钟桶取整")
    expect(HistoryStore.bucketStart(for: fixed, granularity: .twoHours) == 1_764_000_000,
           "2 小时桶取整")

    // 以下用「相对现在」的时间做读写与清理断言（prune 按 now - retention 删，
    // 固定 epoch 的测试数据会被立刻清掉）。
    // 选一个 5 分钟桶起点，使它与 +300 都落在同一个 30 分钟与 2 小时父桶内，
    // 避免测试在整点附近跑的时候父桶被拆成两个。
    var bucket1 = HistoryStore.bucketStart(for: Date(), granularity: .fiveMinutes) - 300
    while bucket1.truncatingRemainder(dividingBy: 1_800) > 1_200
            || bucket1.truncatingRemainder(dividingBy: 7_200) > 1_200 { bucket1 -= 300 }

    // 同桶内两次增量要累加；同应用两条记录也累加
    store.record([
        .init(key: "/Applications/Safari.app", name: "Safari", bytesIn: 1_000, bytesOut: 500),
        .init(key: "/Applications/WeChat.app", name: "微信", bytesIn: 200, bytesOut: 100)
    ], at: Date(timeIntervalSince1970: bucket1 + 60))
    store.record([
        .init(key: "/Applications/Safari.app", name: "Safari", bytesIn: 500, bytesOut: 250)
    ], at: Date(timeIntervalSince1970: bucket1 + 120))
    store.flush(force: true)

    let series = store.series(.fiveMinutes, points: 6, now: Date(timeIntervalSince1970: bucket1 + 60))
    expect(series.count == 6, "6 点序列长度", detail: "\(series.count)")
    expect(series.last?.bytesIn == 1_700, "入站增量累加", detail: "\(series.last?.bytesIn ?? 0)")
    expect(series.last?.bytesOut == 850, "出站增量累加")
    expect(series.last?.time == bucket1, "末点对齐到桶起始")
    expect(series.first?.total == 0, "无记录桶补 0")

    // 跨桶：下一个 5 分钟桶独立累计
    let next = bucket1 + 300
    store.record([.init(key: "/Applications/Safari.app", name: "Safari", bytesIn: 9_000, bytesOut: 0)],
                 at: Date(timeIntervalSince1970: next + 60))
    store.flush(force: true)
    let series2 = store.series(.fiveMinutes, points: 3, now: Date(timeIntervalSince1970: next + 60))
    expect(series2.count == 3, "3 点序列")
    expect(series2.last?.bytesIn == 9_000, "新桶独立累计", detail: "\(series2.last?.bytesIn ?? 0)")
    expect(series2[series2.count - 2].bytesIn == 1_700, "上一个桶保留原值")

    // 聚合层：30 分钟桶 = 同跨度内 5 分钟桶之和；flush 两次都重算过，覆盖写不能翻倍
    let weekSeries = store.series(.thirtyMinutes, points: 2, now: Date(timeIntervalSince1970: next + 60))
    expect(weekSeries.last?.bytesIn == 10_700, "30 分钟桶聚合（覆盖写不翻倍）",
           detail: "\(weekSeries.last?.bytesIn ?? 0)")
    expect(weekSeries.last?.bytesOut == 850, "聚合层出站同步")
    expect(weekSeries.first?.total == 0, "聚合层无记录桶补 0")
    let monthSeries = store.series(.twoHours, points: 1, now: Date(timeIntervalSince1970: next + 60))
    expect(monthSeries.last?.bytesIn == 10_700, "2 小时桶聚合")

    // topApps：范围内按应用合计、总量降序；since 过滤起点
    let top = store.topApps(.fiveMinutes, since: 0, now: Date(timeIntervalSince1970: next + 60))
    expect(top.count == 2, "按应用聚合为 2 条", detail: "\(top.count)")
    expect(top.first?.name == "Safari", "按总量降序")
    expect(top.first?.total == 11_250, "Safari 合计 11250", detail: "\(top.first?.total ?? 0)")
    let sinceNext = store.topApps(.fiveMinutes, since: next, now: Date(timeIntervalSince1970: next + 60))
    expect(sinceNext.count == 1 && sinceNext.first?.bytesIn == 9_000,
           "since 只统计起点之后的桶", detail: "\(sinceNext.count)")

    // prune：超过保留期的桶删除，其余保留
    let ancient = Date(timeIntervalSince1970: bucket1 - 28 * 3_600)   // 28 小时前，超出 26h 保留期
    store.record([.init(key: "/Applications/OldApp.app", name: "老应用", bytesIn: 7_777, bytesOut: 0)],
                 at: ancient)
    store.flush(force: true)
    store.prune()
    let afterPrune = store.topApps(.fiveMinutes, since: 0, now: Date(timeIntervalSince1970: next + 60))
    expect(!afterPrune.contains { $0.name == "老应用" }, "超保留期桶被清理",
           detail: "\(afterPrune.map(\.name))")
    expect(afterPrune.contains { $0.name == "Safari" }, "保留期内数据不受影响")
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
    let emptyHistory = RateHistory(capacity: 60)
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


// MARK: - 系统负载

section("15. 系统负载采样")
do {
    // 32 位节拍回绕：10 核机器约 49.7 天回绕一次，不处理会算出负增长
    expect(SystemLoadProbe.delta(10, 20) == 10, "节拍差分：正常递增")
    expect(SystemLoadProbe.delta(UInt64(UInt32.max), 0) == 1, "节拍差分：回绕边界")
    expect(SystemLoadProbe.delta(UInt64(UInt32.max) - 4, 6) == 11, "节拍差分：跨零回绕")

    let zero = SystemLoadProbe.CPUTicks(user: 0, system: 0, nice: 0, idle: 0)
    let busy = SystemLoadProbe.CPUTicks(user: 30, system: 10, nice: 0, idle: 60)
    let percent = SystemLoadProbe.cpuPercent(previous: zero, current: busy)
    expect(percent.map { abs($0 - 40) < 0.0001 } ?? false,
           "CPU 占用率 = 忙时增量 / 总增量",
           detail: "得到 \(String(describing: percent))，期望 40")
    expect(SystemLoadProbe.cpuPercent(previous: zero, current: zero) == nil,
           "零间隔样本返回 nil（不做除零）")

    let inconsistent = SystemLoadProbe.CPUTicks(user: 200, system: 0, nice: 0, idle: 0)
    expect(SystemLoadProbe.cpuPercent(previous: zero, current: inconsistent) == 100,
           "占用率上限钳制为 100")

    if let first = SystemLoadProbe.cpuTicks() {
        expect(first.total > 0, "真实节拍可读", detail: "total=\(first.total)")
        expect(first.busy <= first.total, "忙时节拍不超过总量")

        Thread.sleep(forTimeInterval: 0.3)
        if let second = SystemLoadProbe.cpuTicks() {
            expect(second.total > first.total, "节拍随时间单调增长",
                   detail: "\(first.total) → \(second.total)")
            let real = SystemLoadProbe.cpuPercent(previous: first, current: second)
            expect(real.map { $0 >= 0 && $0 <= 100 } ?? false,
                   "真实 CPU 占用率落在 0–100", detail: String(describing: real))
        } else {
            expect(false, "第二次节拍采样可用")
        }
    } else {
        expect(false, "首次节拍采样可用")
    }

    if let memory = SystemLoadProbe.memory() {
        expect(memory.total == ProcessInfo.processInfo.physicalMemory,
               "物理内存总量与 ProcessInfo 一致",
               detail: "\(memory.total) vs \(ProcessInfo.processInfo.physicalMemory)")
        expect(memory.used == memory.app + memory.wired + memory.compressed,
               "已用 = 应用 + 联动 + 压缩")
        expect(memory.used <= memory.total, "已用不超过物理内存",
               detail: "\(memory.used) / \(memory.total)")
        expect(memory.cached <= memory.total, "缓存估算不超过物理内存")
        expect((0.0...100.0).contains(memory.percent), "内存占用率落在 0–100",
               detail: String(format: "%.1f%%", memory.percent))
        expect(memory.app <= memory.used && memory.wired <= memory.used
               && memory.compressed <= memory.used,
               "各分项不超过已用总量")
    } else {
        expect(false, "内存采样可用")
    }

    // 历史环形窗口：超出容量后丢最旧的，且百分比按绝对量纲钳制
    var history = LoadHistory(capacity: 60)
    for index in 1...70 { history.append(Double(index)) }
    expect(history.points.count == 60, "历史窗口按容量截断", detail: "\(history.points.count)")
    expect(history.points.first == 11, "截断后保留最新 60 个点",
           detail: "first=\(String(describing: history.points.first))")
    expect(history.points.last == 70, "最新点在最末")
    expect(history.peak == 70, "峰值计算")
    expect(history.average.map { abs($0 - 40.5) < 0.0001 } ?? false,
           "均值计算（11…70 的平均为 40.5）")

    var clamped = LoadHistory(capacity: 10)
    clamped.append(-5)
    clamped.append(120)
    expect(clamped.points == [0, 100], "百分比钳制到 0–100")
    clamped.clear()
    expect(clamped.points.isEmpty && clamped.average == nil, "清空后无残留、均值为空")

    // 用户态 / 内核态拆解：详情面板要展示，必须与总量口径一致
    let split = SystemLoadProbe.cpuBreakdown(previous: zero, current: busy)
    expect(split.map { abs($0.user - 30) < 0.0001 } ?? false,
           "拆解：用户态 30%", detail: String(describing: split?.user))
    expect(split.map { abs($0.system - 10) < 0.0001 } ?? false,
           "拆解：内核态 10%", detail: String(describing: split?.system))
    expect(split.map { abs($0.user + $0.system + $0.idle - 100) < 0.0001 } ?? false,
           "拆解三项合计 100%")
    expect(split.map { abs($0.user + $0.system - 40) < 0.0001 } ?? false,
           "拆解的用户+内核与总占用率一致")
    expect(SystemLoadProbe.cpuBreakdown(previous: zero, current: zero) == nil,
           "拆解：零间隔返回 nil")

    let withNice = SystemLoadProbe.CPUTicks(user: 10, system: 10, nice: 10, idle: 70)
    expect(SystemLoadProbe.cpuBreakdown(previous: zero, current: withNice)
            .map { abs($0.user - 20) < 0.0001 } ?? false,
           "拆解：nice 计入用户态（10+10）")
}

// MARK: - 合并式菜单栏徽标

section("16. 合并式菜单栏徽标")
do {
    // 百分比文本：四舍五入、钳制、无数据占位，全部走同一个实现
    expect(PercentFormat.text(23.4) == "23%", "百分比：23.4 → 23%")
    expect(PercentFormat.text(23.6) == "24%", "百分比：23.6 → 24%")
    expect(PercentFormat.text(-5) == "0%", "百分比：负值钳到 0%")
    expect(PercentFormat.text(120) == "100%", "百分比：超过 100 钳制")
    expect(PercentFormat.text(nil) == "—", "百分比：无数据用破折号")
    expect(PercentFormat.number(7.8) == "8", "数字：不带百分号")

    // 进程占用不钳制：多核并行时 800% 是合法值
    expect(PercentFormat.process(142.4) == "142%", "进程占用：可超过 100%")
    expect(PercentFormat.process(0.42) == "0.4%", "进程占用：小于 10 保留一位小数")
    expect(PercentFormat.process(-3) == "0.0%", "进程占用：负值归零")

    let all = MenuBarBadge.State(cpu: 42, memory: 79,
                                 up: 1_240_000, down: 8_420_000)
    let rendered = MenuBarBadge.render(all)

    expect(rendered.image.size.height == 22, "徽标高度固定 22",
           detail: "\(rendered.image.size.height)")
    expect(rendered.image.isTemplate, "是 template image（跟随菜单栏深浅色）")
    expect(rendered.image.tiffRepresentation != nil, "能光栅化")
    expect(rendered.image.accessibilityDescription?.contains("CPU 42%") == true,
           "无障碍描述含 CPU 数值",
           detail: rendered.image.accessibilityDescription ?? "nil")

    // 三段顺序固定：CPU → 内存 → 网络
    expect(rendered.segments.map(\.slot) == [.cpu, .memory, .network],
           "三段顺序为 CPU / 内存 / 网络",
           detail: rendered.segments.map { "\($0.slot)" }.joined(separator: ","))

    // 段与段之间留出「竖线 + 两侧空隙」，且不重叠
    var ordered = true
    for (previous, next) in zip(rendered.segments, rendered.segments.dropFirst()) {
        let gap = next.frame.minX - previous.frame.maxX
        if gap < 8 || gap > 24 { ordered = false }
    }
    expect(ordered, "相邻段之间留出分隔线空隙（8–24pt）")

    let widths = [9.0, 42.0, 100.0].map {
        MenuBarBadge.imageWidth(MenuBarBadge.State(cpu: $0, memory: 79,
                                                   up: 1_000, down: 9_000))
    }
    expect(widths.max()! - widths.min()! <= 1.0, "整块宽度不随 CPU 数值变化",
           detail: widths.map { String(format: "%.1f", $0) }.joined(separator: "/"))

    let netWidths = [1_000.0, 999_000.0, 12_000_000.0].map {
        MenuBarBadge.imageWidth(MenuBarBadge.State(cpu: 42, memory: 79, up: $0, down: $0))
    }
    expect(netWidths.max()! - netWidths.min()! <= 1.0, "整块宽度不随速率变化",
           detail: netWidths.map { String(format: "%.1f", $0) }.joined(separator: "/"))

    // 关掉某段后，段数减少且整块变窄（需求：三段可分别开关）
    let onlyNetwork = MenuBarBadge.State(cpu: 42, memory: 79, up: 1_000, down: 9_000,
                                         visible: [.network])
    let single = MenuBarBadge.render(onlyNetwork)
    expect(single.segments.map(\.slot) == [.network], "只保留网络段")
    expect(single.image.size.width < rendered.image.size.width, "隐藏两段后整体变窄",
           detail: "\(single.image.size.width) < \(rendered.image.size.width)")

    // 点击命中：段内 → 该段；落在分隔带上 → 右边那段；超出右边界 → 最后一段
    let segments = rendered.segments
    expect(MenuBarBadge.slot(atX: segments[0].frame.midX, segments: segments) == .cpu,
           "点击第一段命中 CPU")
    expect(MenuBarBadge.slot(atX: segments[1].frame.midX, segments: segments) == .memory,
           "点击第二段命中内存")
    expect(MenuBarBadge.slot(atX: segments[2].frame.midX, segments: segments) == .network,
           "点击第三段命中网络")
    expect(MenuBarBadge.slot(atX: segments[1].frame.minX - 6, segments: segments) == .memory,
           "点击竖线附近归右边那段，不留死区")
    expect(MenuBarBadge.slot(atX: 10_000, segments: segments) == .network,
           "超出右边界归最后一段")
    expect(MenuBarBadge.slot(atX: 0, segments: []) == nil, "空段表返回 nil")
}

// MARK: - 进程级采样

section("17. 进程级采样")
do {
    // 差分：1 秒内用掉 1 秒 CPU = 一个核的 100%
    let before: [Int32: UInt64] = [10: 0, 11: 1_000_000_000]
    let current = [
        ProcessLoadSample(pid: 10, name: "a", cpuTime: 1_000_000_000, footprint: 100),
        ProcessLoadSample(pid: 11, name: "b", cpuTime: 2_500_000_000, footprint: 200),
        ProcessLoadSample(pid: 12, name: "c", cpuTime: 9_999_999_999, footprint: 300)
    ]
    let percent = ProcessLoadProbe.cpuPercents(previous: before, current: current, elapsed: 1)
    expect(percent[10].map { abs($0 - 100) < 0.001 } ?? false, "1 秒用满 1 核 = 100%")
    expect(percent[11].map { abs($0 - 150) < 0.001 } ?? false,
           "1.5 秒 CPU / 1 秒墙钟 = 150%（多核可超 100%）")
    expect(percent[12] == nil, "没有上次快照的进程不出数")

    let twoSeconds = ProcessLoadProbe.cpuPercents(previous: [10: 0], current: [
        ProcessLoadSample(pid: 10, name: "a", cpuTime: 1_000_000_000, footprint: 1)
    ], elapsed: 2)
    expect(twoSeconds[10].map { abs($0 - 50) < 0.001 } ?? false, "间隔翻倍则占用率减半")

    let backwards = ProcessLoadProbe.cpuPercents(previous: [10: 5_000_000_000], current: [
        ProcessLoadSample(pid: 10, name: "a", cpuTime: 1_000_000_000, footprint: 1)
    ], elapsed: 1)
    expect(backwards[10] == nil, "累计时间倒退（pid 复用）不出负数")
    expect(ProcessLoadProbe.cpuPercents(previous: [10: 0], current: current, elapsed: 0).isEmpty,
           "零间隔返回空")

    // 聚合：同一应用的多个进程合并成一行
    let samples = [
        ProcessLoadSample(pid: 20, name: "Helper", cpuTime: 0, footprint: 1_000),
        ProcessLoadSample(pid: 21, name: "Helper", cpuTime: 0, footprint: 2_000),
        ProcessLoadSample(pid: 30, name: "Other", cpuTime: 0, footprint: 500)
    ]
    let merged = ProcessLoadProbe.merge(samples,
                                        percent: [20: 30, 21: 12, 30: 5]) { pid, _ in
        pid == 30 ? "other" : "chrome"
    }.sorted { $0.key < $1.key }
    expect(merged.count == 2, "同一个 key 的进程合并为一行", detail: "\(merged.count)")
    expect(merged.first?.processCount == 2, "合并行记录进程数")
    expect(merged.first?.cpu == 42, "合并行 CPU 相加", detail: "\(merged.first?.cpu ?? -1)")
    expect(merged.first?.memory == 3_000, "合并行内存相加")
    expect(merged.first?.pids.sorted() == [20, 21], "合并行保留参与聚合的 pid",
           detail: "\(merged.first?.pids ?? [])")
    expect(merged.last?.pids == [30], "单进程行的 pid 列表只有自己")
    expect(ProcessLoadProbe.terminate(pids: []) == 0, "空 pid 列表不发信号")
    expect(ProcessLoadProbe.terminate(pids: [-1, 0, 1]) == 0, "拒绝 pid ≤ 1（内核与 launchd）")

    // 关闭链路端到端：自己起一个 sleep，SIGTERM 之后应当真的退出
    let victim = Process()
    victim.executableURL = URL(fileURLWithPath: "/bin/sleep")
    victim.arguments = ["60"]
    try? victim.run()
    let victimPID = victim.processIdentifier
    usleep(200_000)
    expect(ProcessLoadProbe.terminate(pids: [victimPID]) == 1, "SIGTERM 成功发给子进程")
    var exited = false
    for _ in 0..<20 {
        usleep(100_000)
        if kill(victimPID, 0) != 0 { exited = true; break }
    }
    expect(exited, "收到 SIGTERM 的子进程已退出")

    // 真实快照：至少要能看到自己这个进程
    let snapshot = ProcessLoadProbe.snapshot()
    let selfPID = ProcessInfo.processInfo.processIdentifier
    expect(!snapshot.isEmpty, "全量快照非空", detail: "\(snapshot.count) 个进程")
    expect(snapshot.contains { $0.pid == selfPID }, "快照包含自检进程自身")
    expect(snapshot.allSatisfy { $0.footprint >= 0 && $0.cpuTime >= 0 }, "字段非负")
    expect(snapshot.filter { $0.footprint > 0 }.count > 10, "多数进程能读到物理内存",
           detail: "\(snapshot.filter { $0.footprint > 0 }.count) 个")

    // 单位换算的端到端验证：忙等 0.25 秒，自己的占用应接近 100%（单核）。
    // rusage 返回的是 mach 节拍而不是纳秒，漏掉 timebase 换算会得到 ~2.4%。
    func sampleSelf() -> ProcessLoadSample? {
        ProcessLoadProbe.snapshot().first { $0.pid == selfPID }
    }
    if let before = sampleSelf() {
        let start = Date()
        while Date().timeIntervalSince(start) < 0.25 {
            _ = sqrt(Double.random(in: 0...1))
        }
        let elapsed = Date().timeIntervalSince(start)
        if let after = sampleSelf() {
            let percent = ProcessLoadProbe.cpuPercents(previous: [selfPID: before.cpuTime],
                                                       current: [after],
                                                       elapsed: elapsed)[selfPID] ?? -1
            expect(percent > 40 && percent < 160,
                   "忙等 0.25 秒自身占用接近单核 100%（时间单位换算正确）",
                   detail: String(format: "%.0f%%", percent))
        }
    }
}

// MARK: - 系统统计

section("18. 系统统计与排序文案")
do {
    // 磁盘：根卷容量必须自洽（可用 ≤ 总量，占用率在 0…1）
    if let stats = SystemStatsProbe.systemStats() {
        expect(stats.diskTotal > 0, "读到根卷容量", detail: ByteFormat.size(stats.diskTotal))
        expect(stats.diskFree <= stats.diskTotal, "可用空间不超过总量")
        expect(stats.diskUsedFraction >= 0 && stats.diskUsedFraction <= 1,
               "占用率在 0…1", detail: String(format: "%.3f", stats.diskUsedFraction))
        expect(!stats.thermal.isEmpty, "散热状态有文案", detail: stats.thermal)
        expect(stats.uptime > 0, "开机时长大于 0")
    } else {
        expect(false, "读到根卷容量")
    }

    // 开机时长文案：面板里只有一格，必须短且不出现 "0 天"
    expect(SystemStatsProbe.uptimeText(0) == "0 分", "不足 1 小时只显示分钟")
    expect(SystemStatsProbe.uptimeText(90) == "1 分", "90 秒 → 1 分")
    expect(SystemStatsProbe.uptimeText(3_600) == "1 小时 0 分", "整点小时带分钟位")
    expect(SystemStatsProbe.uptimeText(90_000) == "1 天 1 小时", "超过一天显示天 + 小时")

    // 散热状态映射（四个档位都是系统公开 API，不会返回空串）
    expect(SystemStatsProbe.thermalLabel(.nominal) == "正常", "nominal → 正常")
    expect(SystemStatsProbe.thermalLabel(.fair) == "偏热", "fair → 偏热")
    expect(SystemStatsProbe.thermalLabel(.serious) == "过热", "serious → 过热")
    expect(SystemStatsProbe.thermalLabel(.critical) == "危险", "critical → 危险")

    // 排序按钮文案：中文不加空格，拉丁缩写两侧留空格
    expect(ProcessMetric.cpu.sortTitle == "按 CPU", "CPU 排序文案两侧留空格",
           detail: ProcessMetric.cpu.sortTitle)
    expect(ProcessMetric.memory.sortTitle == "按内存", "内存排序文案不加空格",
           detail: ProcessMetric.memory.sortTitle)
}

// MARK: - 流量档位元数据

section("19. 流量统计档位元数据")
do {
    // 三层桶宽与点数：日 5 分钟×288 = 24h；周 30 分钟×336 = 7d；月 2 小时×360 = 30d
    expect(HistoryStore.Granularity.allCases.count == 3, "三个持久化粒度")
    expect(HistoryStore.Granularity.fiveMinutes.seconds == 300
           && HistoryStore.Granularity.thirtyMinutes.seconds == 1_800
           && HistoryStore.Granularity.twoHours.seconds == 7_200, "桶宽 300/1800/7200")
    expect(HistoryStore.Granularity.fiveMinutes.displayPoints == 288
           && HistoryStore.Granularity.thirtyMinutes.displayPoints == 336
           && HistoryStore.Granularity.twoHours.displayPoints == 360, "点数 288/336/360")
    expect(300.0 * 288 == 86_400, "日视图覆盖 24 小时")
    expect(1_800.0 * 336 == 604_800, "周视图覆盖 7 天")
    expect(7_200.0 * 360 == 2_592_000, "月视图覆盖 30 天")
    // 桶宽彼此整除，聚合才不需要对不齐
    expect(1_800 % 300 == 0 && 7_200 % 300 == 0 && 7_200 % 1_800 == 0, "三层桶宽整除")
    // 保留期递增且比展示范围更宽（聚合重算要能查到源桶）
    expect(HistoryStore.Granularity.fiveMinutes.retention >= 24 * 3_600
           && HistoryStore.Granularity.thirtyMinutes.retention >= 7 * 86_400
           && HistoryStore.Granularity.twoHours.retention >= 30 * 86_400, "保留期覆盖展示范围")
    expect(HistoryStore.Granularity.fiveMinutes.retention < HistoryStore.Granularity.thirtyMinutes.retention
           && HistoryStore.Granularity.thirtyMinutes.retention < HistoryStore.Granularity.twoHours.retention,
           "保留期随粒度递增")

    // UI 档位 → 持久化粒度映射
    expect(TrafficRange.live.granularity == nil
           && TrafficRange.day.granularity == .fiveMinutes
           && TrafficRange.week.granularity == .thirtyMinutes
           && TrafficRange.month.granularity == .twoHours,
           "档位到粒度的映射")
    expect([TrafficRange.live, .day, .week, .month].map(\.title) == ["实时", "日", "周", "月"],
           "档位标题顺序")
    expect(TrafficRange.day.rangeLabel == "过去 24 小时"
           && TrafficRange.week.rangeLabel == "过去 7 天"
           && TrafficRange.month.rangeLabel == "过去 30 天", "范围文案")
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
