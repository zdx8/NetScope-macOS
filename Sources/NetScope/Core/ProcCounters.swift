import Foundation

/// `nettop -P -x -L 0 -s N -J bytes_in,bytes_out` 单行的解析结果。
///
/// nettop 的 CSV 长这样：
/// ```
/// ,bytes_in,bytes_out,
/// apsd.172,5564,14301,
/// mDNSResponder.268,54175092,3915771,
/// ```
/// 第一列是 `<进程名>.<pid>`，进程名可能含点（如 `com.apple.WebKit.WebContent.1234`），
/// 所以 pid 必须从**最后一个点**后面取。
///
/// 注意：进程名会被 nettop 截断到约 10 个字符（实测 `哔哩哔哩 He.32520`），
/// 因此这个名字只作兜底显示名，真实名称由 ProcessDirectory 用 pid 反查。
public struct RawCounters: Equatable, Sendable {
    public let pid: Int32
    public let rawName: String
    /// 该进程自启动以来的累计入站字节
    public let bytesIn: UInt64
    /// 该进程自启动以来的累计出站字节
    public let bytesOut: UInt64

    public init(pid: Int32, rawName: String, bytesIn: UInt64, bytesOut: UInt64) {
        self.pid = pid
        self.rawName = rawName
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
    }
}

public enum NettopCSV {
    /// 每批数据的起始标记。nettop 每输出一批样本前都会重打表头。
    public static let headerPrefix = ",bytes_in"

    public static func isHeader(_ line: String) -> Bool {
        line.hasPrefix(headerPrefix)
    }

    /// 解析一行数据；表头、空行、格式异常一律返回 nil。
    public static func parse(_ line: String) -> RawCounters? {
        var text = line
        // pty 在 OPOST 关掉后仍是 \n，但不同系统/配置下可能带 \r，统一裁掉
        while text.hasSuffix("\r") || text.hasSuffix("\n") { text.removeLast() }
        guard !text.isEmpty, !isHeader(text) else { return nil }

        let fields = text.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count >= 3 else { return nil }

        let label = String(fields[0])
        guard !label.isEmpty, let dot = label.lastIndex(of: ".") else { return nil }

        let name = String(label[label.startIndex..<dot])
        let pidText = String(label[label.index(after: dot)...])
        guard !name.isEmpty,
              let pid = Int32(pidText), pid > 0,
              let bytesIn = UInt64(fields[1].trimmingCharacters(in: .whitespaces)),
              let bytesOut = UInt64(fields[2].trimmingCharacters(in: .whitespaces))
        else { return nil }

        return RawCounters(pid: pid, rawName: name, bytesIn: bytesIn, bytesOut: bytesOut)
    }

    /// 把一段字节流按行切分，返回完整行与残留尾部。
    /// nettop 的单批输出可达数 KB，一次 read 未必拿到整行，必须自己拼。
    public static func splitLines(_ buffer: inout Data) -> [String] {
        guard !buffer.isEmpty else { return [] }
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newline]
            if let line = String(data: lineData, encoding: .utf8) {
                lines.append(line)
            }
            buffer = buffer[buffer.index(after: newline)...]
        }
        // 防御：若对端长时间不发换行（异常输出），避免无限增长
        if buffer.count > 1 << 20 {
            buffer.removeAll(keepingCapacity: true)
        }
        return lines
    }
}
