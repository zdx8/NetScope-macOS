import Foundation
import Darwin

/// NetScope 用 pty 驱动一个常驻的 `nettop` 子进程。正常退出时会在 `teardownLocked`
/// 里 kill 掉它，但如果主进程被 `SIGKILL`（或者整套进程被外部工具批量终止），
/// 子进程会被 launchd 收养（ppid 变成 1）并继续每秒采样，长期占用 CPU。
///
/// 这里在启动时做一次清扫：只针对 **ppid == 1** 且**可执行文件名是 nettop** 的进程。
/// 用户在终端里手动跑的 nettop，ppid 是 shell 的 pid，不会被误伤。
enum OrphanReaper {
    @discardableResult
    static func reap() -> [pid_t] {
        let capacity = 8192
        var pids = [pid_t](repeating: 0, count: capacity)
        let returned = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids,
                                     Int32(capacity * MemoryLayout<pid_t>.size))
        guard returned > 0 else { return [] }

        // `proc_listpids` 的返回值语义有歧义（文档写字节数，实测更像条目数）。
        // 这里不依赖它：缓冲区预先填 0，遍历全部槽位、跳过空槽即可，
        // 否则会只扫到前 1/4 的进程表，把 pid 较大的孤儿漏掉。
        let structSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        var reaped: [pid_t] = []

        for index in 0..<capacity {
            let pid = pids[index]
            guard pid > 1 else { continue }

            var info = proc_bsdinfo()
            let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, structSize)
            guard result == structSize else { continue }
            guard info.pbi_ppid == 1 else { continue }

            // pbi_name 是 2 * MAXCOMLEN（32 字节）的 C 字符数组；为空时退回 pbi_comm
            var name = withUnsafePointer(to: &info.pbi_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: 32) { String(cString: $0) }
            }
            if name.isEmpty {
                name = withUnsafePointer(to: &info.pbi_comm) { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: 32) { String(cString: $0) }
                }
            }
            guard name == "nettop" else { continue }

            if kill(pid, SIGKILL) == 0 {
                reaped.append(pid)
            }
        }
        return reaped
    }
}
