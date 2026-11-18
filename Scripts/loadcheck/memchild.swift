// 500 MB 触页子进程：分配并触碰 500MB，然后挂着等被杀
import Foundation

let size = 500 * 1024 * 1024
let buf = UnsafeMutableRawBufferPointer.allocate(byteCount: size, alignment: 16384)
var seed: UInt8 = 1
for offset in stride(from: 0, to: size, by: 4096) {
    buf.baseAddress!.advanced(by: offset).storeBytes(of: seed, as: UInt8.self)
    seed &+= 1
}
sleep(120)
