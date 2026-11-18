// 纯用户态空转子进程：无 syscall 的算术循环，时间应几乎全在 user 态
import Foundation

var sink: UInt64 = 0
let deadline = Date().addingTimeInterval(120)
while Date() < deadline {
    for _ in 0..<10_000_000 {
        sink = sink &* 6364136223846793005 &+ 1442695040888963407
    }
}
_ = sink // 防优化掉循环
