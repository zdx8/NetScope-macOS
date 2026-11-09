import Foundation

/// 把字节数格式化成人类可读文本。网络速率统一用 1000 进制
/// （与 macOS 网络面板、路由器、运营商口径一致）。
public enum ByteFormat {
    private static let rateUnits = ["B/s", "KB/s", "MB/s", "GB/s", "TB/s"]
    private static let sizeUnits = ["B", "KB", "MB", "GB", "TB"]

    public static func rate(_ bytesPerSecond: Double) -> String {
        scale(bytesPerSecond, units: rateUnits)
    }

    public static func size(_ bytes: UInt64) -> String {
        scale(Double(bytes), units: sizeUnits)
    }

    /// 需要格式化一个已算好的浮点字节数时用这个重载（避免整数字面量的重载歧义）。
    public static func size(double bytes: Double) -> String {
        scale(bytes, units: sizeUnits)
    }

    /// 菜单栏用的极简形式：`1.2M` / `860K` / `12B`。
    public static func compact(_ bytesPerSecond: Double) -> String {
        let value = max(0, bytesPerSecond)
        if value < 1000 { return "\(Int(value))B" }
        let table: [(Double, String)] = [(1e12, "T"), (1e9, "G"), (1e6, "M"), (1e3, "K")]
        for (factor, suffix) in table where value >= factor {
            let scaled = value / factor
            let text = scaled >= 100 ? String(format: "%.0f", scaled)
                       : scaled >= 10 ? String(format: "%.0f", scaled)
                       : String(format: "%.1f", scaled)
            return text + suffix
        }
        return "\(Int(value))B"
    }

    private static func scale(_ raw: Double, units: [String]) -> String {
        let value = max(0, raw)
        var scaled = value
        var index = 0
        while scaled >= 1000, index < units.count - 1 {
            scaled /= 1000
            index += 1
        }
        if index == 0 {
            return "\(Int(scaled.rounded())) \(units[0])"
        }
        let digits = scaled >= 100 ? 0 : (scaled >= 10 ? 1 : 2)
        return String(format: "%.\(digits)f %@", scaled, units[index])
    }
}
