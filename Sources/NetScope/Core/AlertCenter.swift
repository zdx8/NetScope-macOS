import Foundation
import UserNotifications

/// 某个应用持续占用带宽时发系统通知。
///
/// 三个必要的克制，否则这个功能会变成噪音：
/// 1. **连续命中才算**：瞬时速率很容易冲高（下载刚开始那一秒），单次超阈值就报警会非常吵。
///    要求连续 `minConsecutive` 次采样都超阈值。
/// 2. **按应用冷却**：同一个应用 10 分钟内只提醒一次。
/// 3. **授权失败静默降级**：用户拒绝通知权限时不再尝试，也不弹任何错误。
final class AlertCenter {
    struct Candidate {
        let key: String
        let name: String
        let rate: Double
    }

    private var isAuthorized = false
    private var hasRequested = false
    private var consecutiveHits: [String: Int] = [:]
    private var lastAlertAt: [String: Date] = [:]

    private let cooldown: TimeInterval = 600
    private let minConsecutive = 3

    /// 触发时的回调。无论是否拿到通知权限都会调用 —— 便于自检断言触发时机，
    /// 也方便在日志里留痕。
    var onAlert: ((_ name: String, _ rate: Double) -> Void)?

    var authorizationGranted: Bool { isAuthorized }

    /// 裸可执行文件（`swift build` 产物直接跑）没有 bundle，调用
    /// `UNUserNotificationCenter.current()` 会直接抛异常。所有 UN 入口先过这一关。
    private var notificationsSupported: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    func requestAuthorizationIfNeeded() {
        guard !hasRequested, notificationsSupported else { return }
        hasRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            self?.isAuthorized = granted
            if let error {
                NSLog("NetScope: 通知授权失败 — \(error.localizedDescription)")
            }
        }
    }

    /// 每个采样周期调用一次。
    func evaluate(_ candidates: [Candidate], threshold: Double) {
        guard threshold > 0 else {
            consecutiveHits.removeAll(keepingCapacity: true)
            return
        }

        let now = Date()
        var hitKeys = Set<String>()

        for candidate in candidates where candidate.rate >= threshold {
            hitKeys.insert(candidate.key)
            let count = (consecutiveHits[candidate.key] ?? 0) + 1
            consecutiveHits[candidate.key] = count

            guard count >= minConsecutive else { continue }
            if let last = lastAlertAt[candidate.key], now.timeIntervalSince(last) < cooldown { continue }

            lastAlertAt[candidate.key] = now
            post(name: candidate.name, rate: candidate.rate, threshold: threshold)
        }

        // 掉到阈值以下的应用要把连续计数清零，否则"连续"会跨越很长的时间
        for key in consecutiveHits.keys where !hitKeys.contains(key) {
            consecutiveHits.removeValue(forKey: key)
        }
    }

    func reset() {
        consecutiveHits.removeAll(keepingCapacity: true)
    }

    private func post(name: String, rate: Double, threshold: Double) {
        onAlert?(name, rate)
        guard isAuthorized, notificationsSupported else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(name) 正在占用带宽"
        content.body = "持续超过 \(ByteFormat.rate(threshold))，当前 \(ByteFormat.rate(rate))"
        content.sound = .default
        let request = UNNotificationRequest(identifier: "netscope.\(UUID().uuidString)",
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("NetScope: 发送通知失败 — \(error.localizedDescription)")
            }
        }
    }
}
