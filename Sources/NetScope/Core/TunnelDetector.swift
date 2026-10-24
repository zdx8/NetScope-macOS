import Foundation
import Darwin

/// 判断系统当前是否处于「TUN 型 VPN」状态，以及某个进程是不是 VPN 客户端。
///
/// 为什么需要它：nettop 的 per-process 统计是**按 socket 所在接口**归因的。
/// 开着 TUN 型 VPN 时，同一份数据会出现两次——应用在 `utun*` 上的明文（计给应用），
/// 以及客户端加密后在 `en*` 上的密文（计给客户端）。
///
/// 本工具**不删这些行**：VPN 应用显示的是它在物理链路上的真实字节，删掉就是漏统计。
/// 重复计数的根子由总量侧解决——总量只取 `.physical` 通道。这里负责识别状态，
/// 供界面标注「这行的口径和总量不同」。
///
/// 隧道的判据是 `utun*` 上存在 **IPv4 地址**。macOS 会给每个 utun 都发 `fe80::`
/// 链路本地地址（utun0–4 这类系统内部接口就是这样），用 IPv4 能干净地区分。
enum TunnelDetector {
    /// 已知 VPN / 代理客户端。小写子串匹配，覆盖主流实现。
    /// 宁漏勿错：漏掉只是没去重（回到旧行为），误判会让真实流量消失。
    private static let clientPatterns = [
        "flclash", "clash", "mihomo", "stash", "surge", "shadowrocket", "quantumult",
        "tailscale", "wireguard", "openvpn", "sing-box", "singbox", "v2ray", "xray",
        "trojan", "hysteria", "warp", "networkserviceproxy"
    ]

    /// 返回带 IPv4 地址的 `utun*` 接口名。
    static func activeTunnelNames() -> [String] {
        var result: [String] = []
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(first) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }

            let name = String(cString: current.pointee.ifa_name)
            guard name.hasPrefix("utun") else { continue }
            guard let address = current.pointee.ifa_addr else { continue }
            guard address.pointee.sa_family == UInt8(AF_INET) else { continue }

            let ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            // 0.0.0.0 表示未分配，不算活动隧道
            guard ipv4.sin_addr.s_addr != 0 else { continue }
            if !result.contains(name) { result.append(name) }
        }
        return result
    }

    static func hasActiveTunnel() -> Bool {
        !activeTunnelNames().isEmpty
    }

    /// 进程名是否属于已知 VPN 客户端（大小写不敏感，子串匹配）。
    static func isTunnelClient(_ processName: String) -> Bool {
        let lowered = processName.lowercased()
        guard !lowered.isEmpty else { return false }
        return clientPatterns.contains { lowered.contains($0) }
    }
}
