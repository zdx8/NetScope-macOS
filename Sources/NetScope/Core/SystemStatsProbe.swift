import Foundation

/// 「系统功能」区块要展示的机器级指标。
///
/// 温度与风扇转速需要读 AppleSMC（`IOServiceOpen("AppleSMC")`），实测本机
/// 所有键（含 `#KEY`）都返回 `0x84`（键不可读），SMC 用户客户端在无特权助手时已被封。
/// 所以这里只放**无需特权就能拿到**的三项：磁盘占用、散热压力、开机时长。
/// 数值口径与「关于本机 / 活动监视器」一致，不做估算。
public struct SystemStats: Equatable, Sendable {
    public let diskTotal: UInt64
    public let diskFree: UInt64
    /// 0…1
    public let diskUsedFraction: Double
    /// `ProcessInfo.thermalState` 的中文说明
    public let thermal: String
    /// 距上次开机经过的秒数
    public let uptime: TimeInterval

    public init(diskTotal: UInt64, diskFree: UInt64,
                diskUsedFraction: Double, thermal: String, uptime: TimeInterval) {
        self.diskTotal = diskTotal
        self.diskFree = diskFree
        self.diskUsedFraction = diskUsedFraction
        self.thermal = thermal
        self.uptime = uptime
    }
}

public enum SystemStatsProbe {

    /// 根卷容量。用 `statfs` 而不是 `FileManager.attributesOfFileSystem`：
    /// 后者在某些 APFS 卷上会把 purgeable 计入可用空间，和「关于本机」对不上。
    public static func systemStats() -> SystemStats? {
        var stats = statfs()
        guard statfs("/", &stats) == 0 else { return nil }
        let blockSize = UInt64(stats.f_bsize)
        let total = UInt64(stats.f_blocks) * blockSize
        // 应用可用的剩余空间：f_bavail 是非特权用户可用块数
        let free = UInt64(stats.f_bavail) * blockSize
        guard total > 0 else { return nil }
        return SystemStats(
            diskTotal: total,
            diskFree: free,
            diskUsedFraction: Double(total - free) / Double(total),
            thermal: thermalLabel(ProcessInfo.processInfo.thermalState),
            uptime: ProcessInfo.processInfo.systemUptime
        )
    }

    public static func thermalLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "正常"
        case .fair: return "偏热"
        case .serious: return "过热"
        case .critical: return "危险"
        @unknown default: return "未知"
        }
    }

    /// 「3 天 4 小时」这种紧凑写法，面板里只有一格位置
    public static func uptimeText(_ seconds: TimeInterval) -> String {
        let total = Int(max(seconds, 0))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return "\(days) 天 \(hours) 小时" }
        if hours > 0 { return "\(hours) 小时 \(minutes) 分" }
        return "\(minutes) 分"
    }
}
