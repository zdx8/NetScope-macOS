import Foundation

/// 一条采样通道 = 一个 nettop 子进程 + 一个差分器。
///
/// 本工具需要两条通道才能正确处理 VPN：
/// - `.external` 通道用于**应用归属**（能看到走隧道内的应用）
/// - `.physical` 通道用于**总量**（只算真实网卡字节，不重复计入加密开销）
///
/// 把这一对封装起来，是为了让上层的重启/看门狗/失败计数逻辑对两条通道完全对称，
/// 不必写两套几乎一样的代码。
@MainActor
final class TrafficChannel {
    private(set) var scope: InterfaceScope
    private let sampler = NettopPTY()
    private var aggregator = TrafficAggregator()
    private var lastBatchAt: Date?

    private(set) var consecutiveFailures = 0
    private(set) var sampleCount = 0
    private(set) var lastProcessCount = 0
    private(set) var interval = 1
    private(set) var isRunning = false

    var onBatch: ((BatchDelta, Int) -> Void)?
    var onFailure: ((String) -> Void)?

    init(scope: InterfaceScope) {
        self.scope = scope
    }

    func start(interval: Int, scope newScope: InterfaceScope? = nil) {
        if let newScope, newScope != scope {
            // 换接口范围后旧的累计基准全部失效，必须重置，否则第一批会算出巨大的假差值
            scope = newScope
            aggregator = TrafficAggregator()
            lastBatchAt = nil
            sampleCount = 0
        }
        self.interval = interval
        isRunning = true
        consecutiveFailures = 0
        lastBatchAt = Date()
        sampler.start(interval: interval, scope: scope) { [weak self] batch in
            Task { @MainActor [weak self] in
                self?.handle(batch)
            }
        } onFailure: { [weak self] reason in
            Task { @MainActor [weak self] in
                self?.handleFailure(reason)
            }
        }
    }

    func stop() {
        sampler.stop()
        isRunning = false
    }

    /// 重启通道；可同时换采样间隔与接口范围。
    ///
    /// 换间隔必须重建 nettop（`-s` 是启动参数），而重建会同步 kill + usleep 80ms，
    /// 所以调用方不要在 UI 事件处理中直接调用 —— 走 `DispatchQueue.main.asyncAfter`。
    func restart(interval newInterval: Int? = nil, scope newScope: InterfaceScope? = nil) {
        sampler.stop()
        if let newScope, newScope != scope {
            scope = newScope
            aggregator = TrafficAggregator()
            lastBatchAt = nil
            sampleCount = 0
        }
        start(interval: newInterval ?? interval)
    }

    var secondsSinceLastBatch: TimeInterval {
        guard let lastBatchAt else { return .infinity }
        return Date().timeIntervalSince(lastBatchAt)
    }

    /// 采样流沉默超过 4 个周期即视为卡死
    var isStalled: Bool {
        secondsSinceLastBatch > TimeInterval(max(6, interval * 4))
    }

    private func handle(_ batch: [RawCounters]) {
        lastBatchAt = Date()
        consecutiveFailures = 0
        sampleCount += 1
        lastProcessCount = batch.count
        // 不重置 aggregator：nettop 重启后进程累计值仍来自系统，旧基准依然有效，
        // 重置反而会把重启期间产生的流量丢掉。
        let result = aggregator.ingest(batch, at: Date().timeIntervalSince1970)
        onBatch?(result, batch.count)
    }

    private func handleFailure(_ reason: String) {
        consecutiveFailures += 1
        isRunning = false
        onFailure?(reason)
    }
}
