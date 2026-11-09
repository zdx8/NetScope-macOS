// 读进程的 CPU 时间与物理内存占用（沙箱环境下 top/ps 不可用时的替代方案）。
// 用法：swiftc -O -o /tmp/cpumeter cpumeter.swift && /tmp/cpumeter <pid> [秒]
import Foundation
import Darwin

func snapshot(pid: Int32) -> (cpu: UInt64, footprint: UInt64)? {
    var info = rusage_info_current()
    let result = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
            proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, rebound)
        }
    }
    guard result == 0 else { return nil }
    return (info.ri_user_time + info.ri_system_time, info.ri_phys_footprint)
}

let arguments = CommandLine.arguments
guard arguments.count >= 2, let pid = Int32(arguments[1]) else {
    FileHandle.standardError.write(Data("用法：cpumeter <pid> [秒]\n".utf8))
    exit(2)
}
let window = arguments.count >= 3 ? (Double(arguments[2]) ?? 5.0) : 5.0

guard let first = snapshot(pid: pid) else {
    FileHandle.standardError.write(Data("无法读取 pid \(pid) 的 rusage\n".utf8))
    exit(1)
}
let start = Date()
Thread.sleep(forTimeInterval: window)
guard let second = snapshot(pid: pid) else { exit(1) }
let elapsed = Date().timeIntervalSince(start)

let cpuDelta = Double(second.cpu &- first.cpu) / 1e9
let percent = cpuDelta / elapsed * 100
let memory = Double(second.footprint) / 1024 / 1024

print(String(format: "pid %d  CPU %.2f%%  (%.3f s CPU / %.1f s 墙钟)  内存 %.1f MB",
             pid, percent, cpuDelta, elapsed, memory))
