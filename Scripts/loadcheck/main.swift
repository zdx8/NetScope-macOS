// NetScope CPU / 内存读数真机对照验证
// 直接编译项目探针源码，在受控负载下对照 vm_stat 与按构造已知的负载
import Darwin
import Foundation

var failures = 0
func check(_ name: String, _ cond: Bool, _ detail: String = "") {
    let mark = cond ? "PASS" : "FAIL"
    print("[\(mark)] \(name)\(detail.isEmpty ? "" : "  ·  \(detail)")")
    if !cond { failures += 1 }
}

func shell(_ path: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    try? p.run()
    p.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8) ?? ""
}

var spawned: [pid_t] = []
func spawnBusy() -> pid_t {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
    // 必须 /dev/null：管道缓冲 64K 写满后 yes 会阻塞等读端，CPU 就不满载了
    if let devnull = FileHandle(forWritingAtPath: "/dev/null") {
        p.standardOutput = devnull
    }
    try? p.run()
    spawned.append(p.processIdentifier)
    return p.processIdentifier
}
func spawnSpinner() -> pid_t {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SPINCHILD"] ?? "/tmp/loadcheck/spinchild")
    try? p.run()
    spawned.append(p.processIdentifier)
    return p.processIdentifier
}
func killSpawned() {
    for pid in spawned { kill(pid, SIGKILL) }
    spawned.removeAll()
}
defer { killSpawned() }

func busyPercentOver(seconds: Double) -> (busy: Double, breakdown: SystemLoadProbe.CPUBreakdown?) {
    guard let t0 = SystemLoadProbe.cpuTicks() else { return (-1, nil) }
    Thread.sleep(forTimeInterval: seconds)
    guard let t1 = SystemLoadProbe.cpuTicks() else { return (-1, nil) }
    let percent = SystemLoadProbe.cpuPercent(previous: t0, current: t1) ?? -1
    let breakdown = SystemLoadProbe.cpuBreakdown(previous: t0, current: t1)
    return (percent, breakdown)
}

func snapshot() -> [ProcessLoadSample] {
    let samples = ProcessLoadProbe.snapshot()
    return samples
}

print("== NetScope CPU / 内存读数对照验证 ==")
print("机器: \(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB · \(sysconf(_SC_NPROCESSORS_ONLN)) 逻辑核")
print()

// ============ 1. 内存：与 vm_stat 逐字段对照 ============
print("── 1. 系统内存对照 vm_stat ──")
let vmstatRaw = shell("/usr/bin/vm_stat", [])
let pageSize: Int = {
    if let range = vmstatRaw.range(of: #"page size of (\d+)"#, options: .regularExpression) {
        let text = vmstatRaw[range].dropFirst("page size of ".count)
        return Int(text.filter(\.isNumber)) ?? 16384
    }
    return 16384
}()
func vmstatPages(_ label: String) -> UInt64? {
    for line in vmstatRaw.split(separator: "\n") {
        if line.hasPrefix(label) {
            let digits = line.split(separator: ":").last?
                .compactMap { $0.wholeNumberValue } ?? []
            return UInt64(digits.reduce(0) { $0 * 10 + $1 })
        }
    }
    return nil
}

guard let mem = SystemLoadProbe.memory() else {
    check("内存采样可用", false)
    exit(1)
}
print(String(format: "  探针: 已用 %.2f GB（应用 %.2f + 联动 %.2f + 压缩 %.2f），缓存 %.2f GB，占比 %.1f%%",
              Double(mem.used) / 1073741824, Double(mem.app) / 1073741824,
              Double(mem.wired) / 1073741824, Double(mem.compressed) / 1073741824,
              Double(mem.cached) / 1073741824, mem.percent))

let vmWired = vmstatPages("Pages wired down")
let vmCompressor = vmstatPages("Pages occupied by compressor")
if let vmWired {
    let expect = vmWired * UInt64(pageSize)
    let diff = abs(Double(mem.wired) - Double(expect)) / Double(expect)
    check("联动内存 = vm_stat「Pages wired down」",
          diff < 0.02,   // 两个采样相隔 1–2 秒，活机器上 wired 自然波动（实测最高 ~1.6%）
          "探针 \(ByteSize(mem.wired)) vs vm_stat \(ByteSize(expect))，偏差 \(String(format: "%.2f%%", diff * 100))")
} else { check("vm_stat 输出可解析（wired）", false) }
if let vmCompressor {
    let expect = vmCompressor * UInt64(pageSize)
    let diff = abs(Double(mem.compressed) - Double(expect)) / Double(expect)
    check("压缩内存 = vm_stat「Pages occupied by compressor」",
          diff < 0.01,
          "探针 \(ByteSize(mem.compressed)) vs vm_stat \(ByteSize(expect))，偏差 \(String(format: "%.2f%%", diff * 100))")
} else { check("vm_stat 输出可解析（compressor）", false) }
check("已用 = 应用 + 联动 + 压缩", mem.used == mem.app + mem.wired + mem.compressed)
check("已用不超过物理内存且 > 512 MB", mem.used > 512 * 1024 * 1024 && mem.used <= mem.total,
      "used=\(ByteSize(mem.used)) total=\(ByteSize(mem.total))")

// ============ 2. 进程内存：500 MB 分配子进程的 footprint ============
print("\n── 2. 进程内存 footprint（按构造已知：500 MB）──")
let memChild = Process()
let memChildPath = ProcessInfo.processInfo.environment["MEMCHILD"] ?? "/tmp/loadcheck/memchild"
memChild.executableURL = URL(fileURLWithPath: memChildPath)
try? memChild.run()
spawned.append(memChild.processIdentifier)
Thread.sleep(forTimeInterval: 2.0)
let memSnap = snapshot()
let memChildSample = memSnap.first { $0.pid == memChild.processIdentifier }
check("500MB 子进程可采样", memChildSample != nil)
if let sample = memChildSample {
    let target = 500.0 * 1024 * 1024
    let ratio = Double(sample.footprint) / target
    check("footprint ≈ 500 MB（±8%）",
          ratio > 0.92 && ratio < 1.08,
          "实测 \(ByteSize(sample.footprint))，为目标的 \(String(format: "%.1f%%", ratio * 100))")
    let percent = Double(sample.footprint) / Double(mem.total) * 100
    print("  占物理内存 \(String(format: "%.2f%%", percent))（面板口径同此）")
}

// ============ 3. timebase 换算：忙等子进程累计时间 ============
print("\n── 3. timebase 换算（忙等 2 s → 累计 CPU 时间应 ≈ 2×10⁹ ns）──")
let spinner = spawnBusy()
Thread.sleep(forTimeInterval: 0.3)
let tb0 = snapshot().first { $0.pid == spinner }
Thread.sleep(forTimeInterval: 2.0)
let tb1 = snapshot().first { $0.pid == spinner }
check("忙等子进程在两次快照中都存在", tb0 != nil && tb1 != nil)
if let t0 = tb0, let t1 = tb1 {
    let delta = Double(t1.cpuTime - t0.cpuTime)
    let seconds = delta / 1_000_000_000
    check("cpuTime 增量 ≈ 2 s（0.7–1.15 范围）",
          seconds > 1.4 && seconds < 2.3,
          "实际累计 \(String(format: "%.3f", seconds)) s（若不除 timebase 会是 \(String(format: "%.3f", seconds * 41.6667)) s）")
}

// ============ 4. 进程 CPU%：单核口径 ============
print("\n── 4. 进程 CPU%（单核口径：满载一核 = 100%）──")
let pc0 = snapshot()
Thread.sleep(forTimeInterval: 2.0)
let pc1 = snapshot()
let elapsed = 2.0
let percents = ProcessLoadProbe.cpuPercents(
    previous: Dictionary(uniqueKeysWithValues: pc0.map { ($0.pid, $0.cpuTime) }),
    current: pc1, elapsed: elapsed)
if let p = percents[spinner] {
    check("单个满载子进程 ≈ 100%（±20）", p > 80 && p < 120,
          "实测 \(String(format: "%.1f%%", p))")
} else { check("满载子进程 CPU% 可计算", false) }

// ============ 5. 系统 CPU%：空载基线 vs 4 个纯用户态满载 ============
// 注意：yes> /dev/null 的大量 write() 系统调用会把时间记在内核态，
// 所以验证用户态/系统态拆解必须用无 syscall 的算术空转负载。
print("\n── 5. 系统 CPU%（10 核：4 个满载应 +40% 左右）──")
let baseline = busyPercentOver(seconds: 3.0)
print(String(format: "  空载基线: %.1f%% busy（用户 %.1f · 系统 %.1f）",
              baseline.busy, baseline.breakdown?.user ?? -1, baseline.breakdown?.system ?? -1))

var spinners: [pid_t] = []
for _ in 0..<4 { spinners.append(spawnSpinner()) }
Thread.sleep(forTimeInterval: 0.8)

// 4 个满载下，同时取进程级差分（应各 ≈100%，合计 ≈400 单核单位）
let loaded0 = snapshot()
let loadedTicks0 = SystemLoadProbe.cpuTicks()
Thread.sleep(forTimeInterval: 2.0)
let loaded1 = snapshot()
let loadedTicks1 = SystemLoadProbe.cpuTicks()
let loadedBusy: Double
let loadedBreakdown: SystemLoadProbe.CPUBreakdown?
if let t0 = loadedTicks0, let t1 = loadedTicks1 {
    loadedBusy = SystemLoadProbe.cpuPercent(previous: t0, current: t1) ?? -1
    loadedBreakdown = SystemLoadProbe.cpuBreakdown(previous: t0, current: t1)
} else { loadedBusy = -1; loadedBreakdown = nil }
print(String(format: "  4 核满载: %.1f%% busy（用户 %.1f · 系统 %.1f）",
              loadedBusy, loadedBreakdown?.user ?? -1, loadedBreakdown?.system ?? -1))
check("满载 busy 增量在 25–55 个百分点（期望 +40；基线含机器自用噪声）",
      loadedBusy - baseline.busy > 25 && loadedBusy - baseline.busy < 55,
      "增量 \(String(format: "%.1f", loadedBusy - baseline.busy)) 个百分点")
if let bd = loadedBreakdown, let base = baseline.breakdown {
    let userGain = bd.user - base.user
    let sysGain = bd.system - base.system
    check("纯用户态负载：用户态增量 > 30 个百分点", userGain > 30,
          "用户态 +\(String(format: "%.1f", userGain))")
    check("无 syscall 负载：系统态增量 < 15 个百分点", sysGain < 15,
          "系统态 +\(String(format: "%.1f", sysGain))")
}

// 进程级合计与系统级一致性：4×100 单核单位 ÷ 10 核 = 40%
let loadedPercents = ProcessLoadProbe.cpuPercents(
    previous: Dictionary(uniqueKeysWithValues: loaded0.map { ($0.pid, $0.cpuTime) }),
    current: loaded1, elapsed: 2.0)
let spinnerSum = spinners.reduce(0.0) { sum, pid in sum + (loadedPercents[pid] ?? 0) }
check("4 个满载进程 CPU% 合计 ≈ 400 单核单位（±100）",
      spinnerSum > 300 && spinnerSum < 500,
      "合计 \(String(format: "%.0f", spinnerSum))，折合系统占用 \(String(format: "%.1f%%", spinnerSum / 10))（与系统级增量 \(String(format: "%.1f", loadedBusy - baseline.busy))%% 互证）")
killSpawned()

// 满载停止后仅打印（活机器上基线漂移大，不做断言；核心断言在上面的增量互证里）
Thread.sleep(forTimeInterval: 1.5)
let after = busyPercentOver(seconds: 2.0)
print(String(format: "  [信息] 满载 %.1f%% → 停止后 %.1f%%（基线 %.1f%%；基线含机器自用噪声，不参与判定）",
              loadedBusy, after.busy, baseline.busy))

print()
print(failures == 0 ? "全部通过" : "有 \(failures) 项未通过")
exit(failures == 0 ? 0 : 1)

func ByteSize(_ bytes: UInt64) -> String {
    let gb = Double(bytes) / 1073741824
    if gb >= 1 { return String(format: "%.2f GB", gb) }
    let mb = Double(bytes) / 1048576
    return String(format: "%.1f MB", mb)
}
