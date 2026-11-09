import AppKit
import Darwin

/// 进程的身份信息：显示名、聚合键、图标。
struct ProcessIdentity {
    let displayName: String
    /// 聚合键。同一应用的多进程（主进程 + Helper）必须落到同一个键上。
    let key: String
    let icon: NSImage?
    let isApplication: Bool
}

/// pid → 显示名 / 图标 / 聚合键。
///
/// nettop 给出的进程名被截断到约 10 个字符（实测 `哔哩哔哩 He.32520`），
/// 直接展示很难看，所以真实名称一律用 pid 反查。三层回退：
///
/// 1. `NSWorkspace.runningApplications`：只覆盖「有 UI 的」应用。**Helper 与 XPC 进程
///    的 activationPolicy 是 `.prohibited`，不会出现在这个列表里** —— 只靠它会让
///    Chrome Helper、夸克 Helper 全部落到齿轮图标；
/// 2. `proc_pidpath` + 向上找**最外层** `.app`：`Google Chrome Helper (Renderer)`
///    的可执行文件位于 `Google Chrome.app/Contents/Frameworks/...`，向上能找到
///    `Google Chrome.app`，于是多个 Helper 自动归并成「Google Chrome」一条；
/// 3. 都没有（系统守护进程）才用 nettop 的截断名兜底。
final class ProcessDirectory {
    private let refreshInterval: TimeInterval = 2.0

    private var applications: [Int32: ProcessIdentity] = [:]
    private var lastRefresh = Date.distantPast

    private var pathCache: [Int32: String] = [:]
    private var identityCache: [Int32: ProcessIdentity] = [:]
    private var bundleCache: [String: ProcessIdentity] = [:]

    private static let daemonIcon: NSImage? = {
        let image = NSImage(systemSymbolName: "gearshape.2.fill", accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }()

    func identity(for pid: Int32, rawName: String) -> ProcessIdentity {
        if let cached = identityCache[pid] { return cached }

        // 聚合键只认一个来源：可执行文件路径 → 最外层 .app。
        // 混用「bundleID」和「bundle 路径」会把同一个应用拆成两条
        // （实测 FlClash 的主进程与 Helper 各占一行），所以这里不让两条路径分叉。
        let identity: ProcessIdentity
        let path = executablePath(for: pid)
        if let path, let bundleURL = owningApplicationBundle(path: path) {
            identity = identityForBundle(bundleURL, fallbackName: rawName)
        } else {
            refreshApplicationsIfNeeded()
            if let known = applications[pid] {
                identity = known
            } else if let path {
                let name = (path as NSString).lastPathComponent
                identity = ProcessIdentity(
                    displayName: name.isEmpty ? rawName : name,
                    key: path,
                    icon: ProcessDirectory.daemonIcon,
                    isApplication: false
                )
            } else {
                identity = ProcessIdentity(displayName: rawName, key: rawName, icon: nil, isApplication: false)
            }
        }

        // 缓存上限：长时间运行会累积大量已退出 pid
        if identityCache.count > 600 { identityCache.removeAll(keepingCapacity: true) }
        identityCache[pid] = identity
        return identity
    }

    /// 清理已退出进程的缓存。
    func prune(keeping pids: Set<Int32>) {
        applications = applications.filter { pids.contains($0.key) }
        pathCache = pathCache.filter { pids.contains($0.key) }
        identityCache = identityCache.filter { pids.contains($0.key) }
    }

    // MARK: - 内部

    private func refreshApplicationsIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(lastRefresh) >= refreshInterval else { return }
        lastRefresh = now

        var table: [Int32: ProcessIdentity] = [:]
        for application in NSWorkspace.shared.runningApplications {
            let pid = application.processIdentifier
            guard pid > 0 else { continue }
            let bundleID = application.bundleIdentifier
            let name = application.localizedName ?? bundleID ?? "进程 \(pid)"
            let key: String
            if let bundleID, !bundleID.isEmpty {
                key = bundleID
            } else if let url = application.bundleURL {
                key = url.path
            } else {
                key = name
            }
            table[pid] = ProcessIdentity(
                displayName: name,
                key: key,
                icon: application.icon,
                isApplication: true
            )
        }
        applications = table
    }

    private func identityForBundle(_ url: URL, fallbackName: String) -> ProcessIdentity {
        let path = url.path
        if let cached = bundleCache[path] { return cached }

        // 优先取 bundle 自报的显示名。不用 FileManager.displayName 作首选：
        // 它遵循访达"显示所有文件扩展名"的设置，实测会返回 "WorkBuddy.app"。
        var name = ""
        if let bundle = Bundle(url: url) {
            let info = bundle.localizedInfoDictionary ?? bundle.infoDictionary
            if let display = info?["CFBundleDisplayName"] as? String, !display.isEmpty {
                name = display
            } else if let short = info?["CFBundleName"] as? String, !short.isEmpty {
                name = short
            }
        }
        if name.isEmpty {
            name = FileManager.default.displayName(atPath: path)
        }
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        if name.isEmpty { name = fallbackName }

        let identity = ProcessIdentity(
            displayName: name,
            key: path,
            icon: NSWorkspace.shared.icon(forFile: path),
            isApplication: true
        )
        bundleCache[path] = identity
        return identity
    }

    /// 沿可执行文件路径向上，返回**最外层**的 `.app` bundle。
    /// 取最外层而不是最近的一个，才能把 `Chrome Helper (Renderer).app` 归并到 `Google Chrome.app`。
    private func owningApplicationBundle(path: String) -> URL? {
        var url = URL(fileURLWithPath: path)
        var outermost: URL?
        var guardCounter = 0
        while url.path != "/", !url.path.isEmpty, guardCounter < 40 {
            guardCounter += 1
            if url.pathExtension == "app" { outermost = url }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        return outermost
    }

    private func executablePath(for pid: Int32) -> String? {
        if let cached = pathCache[pid] { return cached }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(MAXPATHLEN))
        guard length > 0 else { return nil }
        let path = String(cString: buffer)
        guard !path.isEmpty else { return nil }
        pathCache[pid] = path
        return path
    }
}
