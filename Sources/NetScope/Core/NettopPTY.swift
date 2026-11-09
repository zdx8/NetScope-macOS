import Foundation
import Darwin

/// nettop 的 `-t` 接口筛选范围。
///
/// 这两个范围是本工具做 VPN 去重的基础：
/// - `external` 是所有非 loopback 接口，包含 `utun*` 隧道。走 VPN 的应用，其明文流量
///   出现在隧道上 —— 这是**应用归属**的真实来源。
/// - `physical` 只有 `wifi` / `wired`（即 en*）。VPN 客户端把隧道内的明文再加密后
///   送到物理链路，所以只有它反映**网卡真实跑了多少字节**。
///
/// 两者相加会得到近似两倍的数字，这正是「走 VPN 时总量偏高」的根因。
public enum InterfaceScope: String, Sendable {
    case external
    case physical

    var nettopArguments: [String] {
        switch self {
        case .external:
            return ["-t", "external"]
        case .physical:
            return ["-t", "wifi", "-t", "wired"]
        }
    }
}

/// 通过 pty 驱动 `/usr/bin/nettop`，实时读取 CSV 格式的按进程流量计数。
///
/// 为什么必须用 pty：
/// - `nettop -L N` 是**固定 30 秒**的采样窗口，与 N、`-s` 都无关，无法用来秒级采样；
/// - `nettop -L 0`（无限）走管道时 stdout 是全缓冲（4 KB 才刷一次），实测数秒延迟，
///   且进程被终止时缓冲区里的数据全部丢失；
/// - 把 stdout 接到伪终端后 nettop 变为行缓冲，输出即时可读，并且仍是纯文本 CSV
///   （不会切换到 curses 全屏界面）。
///
/// 数据语义：每批输出的是**进程自启动以来的累计字节**，速率由上层差分得到。
public final class NettopPTY {
    public enum Failure: Error, CustomStringConvertible {
        case ptyUnavailable(Int32)
        case spawnFailed(Int32)
        case streamEnded
        case readFailed(Int32)

        public var description: String {
            switch self {
            case .ptyUnavailable(let code): return "无法分配伪终端（errno \(code)）"
            case .spawnFailed(let code): return "无法启动 nettop（errno \(code)）"
            case .streamEnded: return "nettop 输出已结束"
            case .readFailed(let code): return "读取 nettop 输出失败（errno \(code)）"
            }
        }
    }

    private let ioQueue = DispatchQueue(label: "com.netscope.nettop.io", qos: .utility)
    private var masterFD: Int32 = -1
    private var childPID: pid_t = 0
    private var readSource: DispatchSourceRead?
    private var buffer = Data()
    private var currentBatch: [RawCounters] = []

    private var onBatch: (([RawCounters]) -> Void)?
    private var onFailure: ((String) -> Void)?

    public private(set) var isRunning = false
    public private(set) var batchCount = 0
    private var startedAt: Date?

    public init() {}

    /// - Parameters:
    ///   - interval: nettop 的采样间隔（秒）。nettop 的 `-s` 只接受整数，最小 1。
    ///   - onBatch: 每收到一整批样本回调一次（在内部串行队列上，调用方自行切线程）。
    ///   - onFailure: 子进程异常结束时回调，参数是可直接展示的原因描述。
    public func start(interval: Int = 1,
                      scope: InterfaceScope = .external,
                      onBatch: @escaping ([RawCounters]) -> Void,
                      onFailure: @escaping (String) -> Void) {
        stop()
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.onBatch = onBatch
            self.onFailure = onFailure
            self.batchCount = 0
            self.buffer.removeAll(keepingCapacity: true)
            self.currentBatch.removeAll(keepingCapacity: true)
            do {
                try self.spawnLocked(interval: max(1, min(interval, 10)), scope: scope)
                self.installReadSourceLocked()
                self.isRunning = true
                self.startedAt = Date()
            } catch {
                let message = (error as? Failure)?.description ?? "\(error)"
                self.isRunning = false
                DispatchQueue.main.async { onFailure(message) }
            }
        }
    }

    public func stop() {
        ioQueue.sync {
            teardownLocked()
        }
    }

    /// 距离上次收到样本的秒数；用于 watchdog 判定采样是否卡死。
    public var secondsSinceLastBatch: TimeInterval {
        guard let startedAt else { return 0 }
        return Date().timeIntervalSince(startedAt)
    }

    // MARK: - 内部实现

    private func spawnLocked(interval: Int, scope: InterfaceScope) throws {
        var master: Int32 = 0
        var slave: Int32 = 0
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            throw Failure.ptyUnavailable(errno)
        }

        // 关掉输出后处理与回显：否则换行会被改写成 \r\n，且 nettop 的提示会回显到流里
        var attributes = termios()
        if tcgetattr(slave, &attributes) == 0 {
            attributes.c_oflag &= ~UInt(OPOST)
            attributes.c_lflag &= ~UInt(ECHO | ECHONL)
            tcsetattr(slave, TCSANOW, &attributes)
        }

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDERR_FILENO)

        var spawnAttributes: posix_spawnattr_t?
        posix_spawnattr_init(&spawnAttributes)
        defer { posix_spawnattr_destroy(&spawnAttributes) }
        // 独立会话：nettop 不会因为我们自己的控制终端收到信号而被打断
        posix_spawnattr_setflags(&spawnAttributes, Int16(POSIX_SPAWN_SETSID))

        var arguments = [
            "/usr/bin/nettop",
            "-P",              // 只输出按进程汇总
            "-x",              // 数字不带单位后缀
            "-L", "0",         // CSV 模式，0 = 无限
            "-s", "\(interval)",
            "-J", "bytes_in,bytes_out"
        ]
        arguments.append(contentsOf: scope.nettopArguments)

        var cArguments: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        cArguments.append(nil)
        defer { for pointer in cArguments where pointer != nil { free(pointer) } }

        var pid: pid_t = 0
        let result = cArguments.withUnsafeMutableBufferPointer { buffer in
            posix_spawn(&pid, "/usr/bin/nettop", &fileActions, &spawnAttributes, buffer.baseAddress, environ)
        }
        // 父进程必须关闭 slave，否则 master 侧永远读不到 EOF
        close(slave)

        guard result == 0 else {
            close(master)
            throw Failure.spawnFailed(result)
        }

        masterFD = master
        childPID = pid
        _ = fcntl(masterFD, F_SETFL, O_NONBLOCK)
    }

    private func installReadSourceLocked() {
        let fd = masterFD
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
        source.setEventHandler { [weak self] in
            self?.handleReadable()
        }
        source.setCancelHandler {
            close(fd)
        }
        readSource = source
        source.resume()
    }

    private func handleReadable() {
        guard masterFD >= 0 else { return }
        var chunk = [UInt8](repeating: 0, count: 16384)
        let count = read(masterFD, &chunk, chunk.count)
        if count > 0 {
            buffer.append(contentsOf: chunk[0..<count])
            for line in NettopCSV.splitLines(&buffer) {
                consumeLocked(line)
            }
        } else if count == 0 {
            failLocked(Failure.streamEnded.description)
        } else if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
            return
        } else {
            failLocked(Failure.readFailed(errno).description)
        }
    }

    private func consumeLocked(_ line: String) {
        if NettopCSV.isHeader(line) {
            // 表头出现即代表上一批已经完整下发
            if !currentBatch.isEmpty {
                let batch = currentBatch
                currentBatch.removeAll(keepingCapacity: true)
                batchCount += 1
                startedAt = Date()
                onBatch?(batch)
            }
            return
        }
        if let row = NettopCSV.parse(line) {
            currentBatch.append(row)
        }
    }

    private func failLocked(_ reason: String) {
        let handler = onFailure
        teardownLocked()
        if let handler {
            DispatchQueue.main.async { handler(reason) }
        }
    }

    private func teardownLocked() {
        if let source = readSource {
            // setCancelHandler 负责 close(fd)，这里只取消
            source.cancel()
            readSource = nil
        }
        masterFD = -1
        if childPID > 0 {
            let pid = childPID
            // 实测：nettop 在 pty 下**忽略 SIGTERM**（同一命令在管道下会正常退出）。
            // kill(2) 依然返回 0，光看返回值会误判成"已经清理"。因此必须补一刀 SIGKILL，
            // 否则进程被 launchd 收养后会在后台继续每秒采样。
            kill(pid, SIGTERM)
            usleep(80_000)
            if kill(pid, 0) == 0 {
                kill(pid, SIGKILL)
            }
            childPID = 0
        }
        isRunning = false
        currentBatch.removeAll(keepingCapacity: true)
        buffer.removeAll(keepingCapacity: true)
    }

    deinit {
        if masterFD >= 0 { close(masterFD) }
        if childPID > 0 { kill(childPID, SIGTERM) }
    }
}
