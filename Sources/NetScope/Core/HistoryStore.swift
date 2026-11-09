import Foundation
import SQLite3

/// 按天持久化每个应用的累计流量，用于「今天/本周谁用得最多」。
///
/// 用系统自带的 libsqlite3，不引入任何第三方依赖。
///
/// 写入做了节流：采样每秒一次，但每 30 秒才落盘一次。逐秒 UPSERT 会把磁盘写入放大 30 倍，
/// 而这份数据的粒度本来就只是「天」—— 崩溃最多丢 30 秒，可以接受。
final class HistoryStore {
    struct AppEntry: Identifiable {
        let key: String
        let name: String
        let bytesIn: UInt64
        let bytesOut: UInt64
        var id: String { key }
        var total: UInt64 { bytesIn &+ bytesOut }
    }

    struct DayTotal {
        let day: String
        let bytesIn: UInt64
        let bytesOut: UInt64
        var total: UInt64 { bytesIn &+ bytesOut }
    }

    private struct Pending {
        var day: String
        var key: String
        var name: String
        var bytesIn: UInt64
        var bytesOut: UInt64
    }

    private let queue = DispatchQueue(label: "com.netscope.history", qos: .utility)
    private let lock = NSLock()
    private var pending: [String: Pending] = [:]
    private var lastFlush = Date.distantPast
    private let flushInterval: TimeInterval = 30
    private var db: OpaquePointer?
    private var isClosed = false

    /// 打开（或创建）数据库。失败时返回 nil，调用方应降级为"无历史"而不是崩溃。
    init?(path: String) {
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            return nil
        }
        db = handle
        // WAL 让读写不互相阻塞；数据量很小，正常模式下也没问题，但这样更稳
        _ = exec("PRAGMA journal_mode=WAL;")
        _ = exec("""
        CREATE TABLE IF NOT EXISTS daily_app_traffic (
            day TEXT NOT NULL,
            app_key TEXT NOT NULL,
            app_name TEXT NOT NULL,
            bytes_in INTEGER NOT NULL DEFAULT 0,
            bytes_out INTEGER NOT NULL DEFAULT 0,
            updated_at REAL NOT NULL,
            PRIMARY KEY (day, app_key)
        );
        """)
        _ = exec("CREATE INDEX IF NOT EXISTS idx_day ON daily_app_traffic(day);")
    }

    deinit {
        close()
    }

    /// 默认位置：`~/Library/Application Support/NetScope/traffic.db`
    static func defaultPath() -> String? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else { return nil }
        let directory = base.appendingPathComponent("NetScope", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("traffic.db").path
    }

    // MARK: - 写入

    /// 累积一批增量（不落盘，纯内存操作，可以在采样回调里每秒调用）。
    func record(_ rows: [AppEntry], at date: Date = Date()) {
        guard !rows.isEmpty else { return }
        let day = Self.dayString(for: date)
        lock.lock()
        for row in rows {
            let compound = "\(day)|\(row.key)"
            if var existing = pending[compound] {
                existing.bytesIn &+= row.bytesIn
                existing.bytesOut &+= row.bytesOut
                existing.name = row.name
                pending[compound] = existing
            } else {
                pending[compound] = Pending(day: day, key: row.key, name: row.name,
                                            bytesIn: row.bytesIn, bytesOut: row.bytesOut)
            }
        }
        let due = Date().timeIntervalSince(lastFlush) >= flushInterval
        lock.unlock()

        if due { flush() }
    }

    /// 把内存里的增量写入数据库。`force` 为 true 时忽略节流（退出前调用）。
    func flush(force: Bool = false) {
        lock.lock()
        if !force, Date().timeIntervalSince(lastFlush) < flushInterval {
            lock.unlock()
            return
        }
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        lastFlush = Date()
        lock.unlock()

        guard !batch.isEmpty else { return }
        queue.async { [weak self] in
            self?.write(batch)
        }
    }

    private func write(_ batch: [String: Pending]) {
        guard let db, !isClosed else { return }
        let sql = """
        INSERT INTO daily_app_traffic(day, app_key, app_name, bytes_in, bytes_out, updated_at)
        VALUES(?,?,?,?,?,?)
        ON CONFLICT(day, app_key) DO UPDATE SET
            bytes_in = bytes_in + excluded.bytes_in,
            bytes_out = bytes_out + excluded.bytes_out,
            app_name = excluded.app_name,
            updated_at = excluded.updated_at;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return }
        defer { sqlite3_finalize(statement) }

        _ = exec("BEGIN IMMEDIATE;")
        let now = Date().timeIntervalSince1970
        for entry in batch.values {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_text(statement, 1, entry.day, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, entry.key, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 3, entry.name, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(statement, 4, Int64(clamping: entry.bytesIn))
            sqlite3_bind_int64(statement, 5, Int64(clamping: entry.bytesOut))
            sqlite3_bind_double(statement, 6, now)
            sqlite3_step(statement)
        }
        _ = exec("COMMIT;")
    }

    // MARK: - 查询

    /// 指定日期区间（含今天往前 days-1 天）的总量。
    func total(days: Int) -> DayTotal {
        let range = Self.recentDays(days)
        guard let first = range.first else {
            return DayTotal(day: "", bytesIn: 0, bytesOut: 0)
        }
        let placeholders = range.map { _ in "?" }.joined(separator: ",")
        let sql = """
        SELECT COALESCE(SUM(bytes_in),0), COALESCE(SUM(bytes_out),0)
        FROM daily_app_traffic WHERE day IN (\(placeholders));
        """
        var sumIn: UInt64 = 0
        var sumOut: UInt64 = 0
        queue.sync {
            guard let db else { return }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return }
            defer { sqlite3_finalize(statement) }
            for (index, day) in range.enumerated() {
                sqlite3_bind_text(statement, Int32(index + 1), day, -1, SQLITE_TRANSIENT)
            }
            if sqlite3_step(statement) == SQLITE_ROW {
                sumIn = UInt64(max(0, sqlite3_column_int64(statement, 0)))
                sumOut = UInt64(max(0, sqlite3_column_int64(statement, 1)))
            }
        }
        return DayTotal(day: first, bytesIn: sumIn, bytesOut: sumOut)
    }

    /// 今天（或指定日期）消耗最多的应用。
    func topApps(day: String? = nil, limit: Int = 5) -> [AppEntry] {
        let target = day ?? Self.dayString(for: Date())
        let sql = """
        SELECT app_key, app_name, bytes_in, bytes_out
        FROM daily_app_traffic WHERE day = ?
        ORDER BY (bytes_in + bytes_out) DESC LIMIT ?;
        """
        var result: [AppEntry] = []
        queue.sync {
            guard let db else { return }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, target, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(statement, 2, Int32(limit))
            while sqlite3_step(statement) == SQLITE_ROW {
                let key = String(cString: sqlite3_column_text(statement, 0))
                let name = String(cString: sqlite3_column_text(statement, 1))
                let bytesIn = UInt64(max(0, sqlite3_column_int64(statement, 2)))
                let bytesOut = UInt64(max(0, sqlite3_column_int64(statement, 3)))
                result.append(AppEntry(key: key, name: name, bytesIn: bytesIn, bytesOut: bytesOut))
            }
        }
        return result
    }

    /// 最近 N 天每天的总量（用于柱状图），按日期升序返回。
    func dailyTotals(days: Int) -> [DayTotal] {
        let range = Self.recentDays(days)
        guard !range.isEmpty else { return [] }
        let placeholders = range.map { _ in "?" }.joined(separator: ",")
        let sql = """
        SELECT day, COALESCE(SUM(bytes_in),0), COALESCE(SUM(bytes_out),0)
        FROM daily_app_traffic WHERE day IN (\(placeholders))
        GROUP BY day;
        """
        var byDay: [String: DayTotal] = [:]
        queue.sync {
            guard let db else { return }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return }
            defer { sqlite3_finalize(statement) }
            for (index, day) in range.enumerated() {
                sqlite3_bind_text(statement, Int32(index + 1), day, -1, SQLITE_TRANSIENT)
            }
            while sqlite3_step(statement) == SQLITE_ROW {
                let day = String(cString: sqlite3_column_text(statement, 0))
                byDay[day] = DayTotal(
                    day: day,
                    bytesIn: UInt64(max(0, sqlite3_column_int64(statement, 1))),
                    bytesOut: UInt64(max(0, sqlite3_column_int64(statement, 2)))
                )
            }
        }
        // 没有记录的日期补 0，保证柱状图的横轴连续
        return range.map { byDay[$0] ?? DayTotal(day: $0, bytesIn: 0, bytesOut: 0) }
    }

    /// 删除超过保留期的记录。
    func prune(keepDays: Int = 120) {
        guard let cutoff = Self.recentDays(keepDays).first else { return }
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM daily_app_traffic WHERE day < ?;", -1, &statement, nil) == SQLITE_OK,
                  let statement else { return }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, cutoff, -1, SQLITE_TRANSIENT)
            sqlite3_step(statement)
        }
    }

    func close() {
        flush(force: true)
        queue.sync {
            guard let db, !isClosed else { return }
            isClosed = true
            sqlite3_close(db)
            self.db = nil
        }
    }

    // MARK: - 工具

    static func dayString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// 返回最近 days 天的日期字符串，从旧到新，最后一个是今天。
    static func recentDays(_ days: Int) -> [String] {
        guard days > 0 else { return [] }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<days).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return dayString(for: date)
        }
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        guard let db else { return false }
        return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }
}

/// sqlite3_bind_text 需要「让 SQLite 自己拷贝字符串」的析构器。
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
