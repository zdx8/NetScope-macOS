import Foundation
import SQLite3

/// 分层时间桶持久化：按应用把流量增量写进 **5 分钟原始桶**，
/// 落盘时顺带把受影响的父桶（30 分钟、2 小时）重算覆盖，三种视图各查各的层。
///
/// - 日图表：5 分钟均值 × 288 点（过去 24 小时）
/// - 周图表：30 分钟均值 × 336 点（过去 7 天）
/// - 月图表：2 小时均值 × 360 点（过去 30 天）
///
/// 为什么分三层而不是只存 5 分钟桶再现算：月视图要扫 30 天 × 288 桶 ≈ 一万多桶，
/// 每次打开面板都聚合太重；提前把父桶算好，月视图只扫 372 个 2 小时桶。
/// 覆盖写（DELETE + INSERT SELECT）而不是累加 UPSERT，是因为同一个父桶会被
/// 反复重算，累加会把旧值越加越大。
///
/// 写入节流 30 秒：采样每秒一次，落盘每 30 秒一次，崩溃最多丢 30 秒。
/// 1.2.1 及之前的按天表 `daily_app_traffic` 就此退役：不再写入，库里的旧数据保留不动。
final class HistoryStore {
    struct AppEntry: Identifiable {
        let key: String
        let name: String
        let bytesIn: UInt64
        let bytesOut: UInt64
        var id: String { key }
        var total: UInt64 { bytesIn &+ bytesOut }
    }

    /// 一条速率曲线点：`time` 是桶起始 epoch 秒，字节量是该桶内的累计
    struct SamplePoint: Identifiable {
        let time: TimeInterval
        let bytesIn: UInt64
        let bytesOut: UInt64
        var id: TimeInterval { time }
        var total: UInt64 { bytesIn &+ bytesOut }
    }

    /// 桶宽（秒）与展示点数。三个粒度彼此整除，聚合不需要对不齐。
    enum Granularity: Int, CaseIterable {
        case fiveMinutes = 0
        case thirtyMinutes = 1
        case twoHours = 2

        var seconds: TimeInterval {
            switch self {
            case .fiveMinutes: return 300
            case .thirtyMinutes: return 1_800
            case .twoHours: return 7_200
            }
        }

        /// 图表展示的点数（过去 24h / 7 天 / 30 天）
        var displayPoints: Int {
            switch self {
            case .fiveMinutes: return 288      // 24h
            case .thirtyMinutes: return 336    // 7d
            case .twoHours: return 360         // 30d
            }
        }

        /// 这一层的数据要保留多久（多留一点余量，聚合重算需要能查到源桶）
        var retention: TimeInterval {
            switch self {
            case .fiveMinutes: return 26 * 3_600      // 26h
            case .thirtyMinutes: return 8.5 * 86_400  // 8.5 天
            case .twoHours: return 31.5 * 86_400      // 31.5 天
            }
        }
    }

    private let queue = DispatchQueue(label: "com.netscope.history", qos: .utility)
    private let lock = NSLock()
    private var pending: [String: Pending] = [:]
    private var lastFlush = Date.distantPast
    private let flushInterval: TimeInterval = 30
    private var db: OpaquePointer?
    private var isClosed = false

    private struct Pending {
        var bucket: TimeInterval
        var key: String
        var name: String
        var bytesIn: UInt64
        var bytesOut: UInt64
    }

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
        CREATE TABLE IF NOT EXISTS traffic_samples (
            granularity INTEGER NOT NULL,
            bucket INTEGER NOT NULL,
            app_key TEXT NOT NULL,
            app_name TEXT NOT NULL,
            bytes_in INTEGER NOT NULL DEFAULT 0,
            bytes_out INTEGER NOT NULL DEFAULT 0,
            updated_at REAL NOT NULL,
            PRIMARY KEY (granularity, bucket, app_key)
        );
        """)
        _ = exec("CREATE INDEX IF NOT EXISTS idx_samples_bucket ON traffic_samples(granularity, bucket);")
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
    /// 增量先在内存里归并进当前的 5 分钟桶。
    func record(_ rows: [AppEntry], at date: Date = Date()) {
        guard !rows.isEmpty else { return }
        let bucket = Self.bucketStart(for: date, granularity: .fiveMinutes)
        lock.lock()
        for row in rows {
            let compound = "\(Int(bucket))|\(row.key)"
            if var existing = pending[compound] {
                existing.bytesIn &+= row.bytesIn
                existing.bytesOut &+= row.bytesOut
                existing.name = row.name
                pending[compound] = existing
            } else {
                pending[compound] = Pending(bucket: bucket, key: row.key, name: row.name,
                                            bytesIn: row.bytesIn, bytesOut: row.bytesOut)
            }
        }
        let due = Date().timeIntervalSince(lastFlush) >= flushInterval
        lock.unlock()

        if due { flush() }
    }

    /// 把内存里的增量写入数据库并重算受影响的父桶。`force` 为 true 时忽略节流（退出前调用）。
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
        // 受影响的父桶：从批次实际所属的 5 分钟桶推算（flush 可能横跨两个 5 分钟桶，
        // 用「当前时间」算会漏掉上一个桶的父桶）
        let parentBuckets = Set(batch.values.flatMap { entry -> [TimeInterval] in
            let source = Date(timeIntervalSince1970: entry.bucket)
            return [Self.bucketStart(for: source, granularity: .thirtyMinutes),
                    Self.bucketStart(for: source, granularity: .twoHours)]
        })
        queue.async { [weak self] in
            self?.write(batch, parents: Array(parentBuckets))
        }
    }

    private func write(_ batch: [String: Pending], parents: [TimeInterval]) {
        guard let db, !isClosed else { return }
        let upsert = """
        INSERT INTO traffic_samples(granularity, bucket, app_key, app_name, bytes_in, bytes_out, updated_at)
        VALUES(?,?,?,?,?,?,?)
        ON CONFLICT(granularity, bucket, app_key) DO UPDATE SET
            bytes_in = bytes_in + excluded.bytes_in,
            bytes_out = bytes_out + excluded.bytes_out,
            app_name = excluded.app_name,
            updated_at = excluded.updated_at;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, upsert, -1, &statement, nil) == SQLITE_OK, let statement else { return }
        defer { sqlite3_finalize(statement) }

        _ = exec("BEGIN IMMEDIATE;")
        let now = Date().timeIntervalSince1970
        for entry in batch.values {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_int64(statement, 1, Int64(Granularity.fiveMinutes.rawValue))
            sqlite3_bind_int64(statement, 2, Int64(entry.bucket))
            sqlite3_bind_text(statement, 3, entry.key, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 4, entry.name, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(statement, 5, Int64(clamping: entry.bytesIn))
            sqlite3_bind_int64(statement, 6, Int64(clamping: entry.bytesOut))
            sqlite3_bind_double(statement, 7, now)
            sqlite3_step(statement)
        }
        for parent in parents {
            Self.reaggregate(parentBucket: parent, in: self)
        }
        _ = exec("COMMIT;")
    }

    /// 重算一个父桶：删掉旧的聚合行，从 5 分钟源桶重新 SUM。
    /// `parentBucket` 必须是已经对齐到父桶宽度的起始 epoch（调用方用 bucketStart 取整后传入）。
    /// 必须在事务内、持有 db 的线程上调用。
    static func reaggregate(parentBucket: TimeInterval, in store: HistoryStore) {
        guard let db = store.db else { return }
        let aligned = parentBucket
        let source: Granularity = .fiveMinutes
        for parent: Granularity in [.thirtyMinutes, .twoHours] {
            var delete: OpaquePointer?
            let deleteSQL = "DELETE FROM traffic_samples WHERE granularity=? AND bucket=?;"
            if sqlite3_prepare_v2(db, deleteSQL, -1, &delete, nil) == SQLITE_OK, let delete {
                sqlite3_bind_int64(delete, 1, Int64(parent.rawValue))
                sqlite3_bind_int64(delete, 2, Int64(aligned))
                sqlite3_step(delete)
                sqlite3_finalize(delete)
            }
            var insert: OpaquePointer?
            let insertSQL = """
            INSERT INTO traffic_samples(granularity, bucket, app_key, app_name, bytes_in, bytes_out, updated_at)
            SELECT ?, ?, app_key, app_name, SUM(bytes_in), SUM(bytes_out), MAX(updated_at)
            FROM traffic_samples WHERE granularity=? AND bucket>=? AND bucket<? GROUP BY app_key;
            """
            if sqlite3_prepare_v2(db, insertSQL, -1, &insert, nil) == SQLITE_OK, let insert {
                sqlite3_bind_int64(insert, 1, Int64(parent.rawValue))
                sqlite3_bind_int64(insert, 2, Int64(aligned))
                sqlite3_bind_int64(insert, 3, Int64(source.rawValue))
                sqlite3_bind_int64(insert, 4, Int64(aligned))
                sqlite3_bind_int64(insert, 5, Int64(aligned + parent.seconds))
                sqlite3_step(insert)
                sqlite3_finalize(insert)
            }
        }
    }

    // MARK: - 查询

    /// 最近 `points` 个桶的合计（所有应用），缺桶补 0，按时间升序。
    /// `now` 只在测试里传入，生产用当前时间。
    func series(_ granularity: Granularity, points: Int, now: Date = Date()) -> [SamplePoint] {
        let latest = Self.bucketStart(for: now, granularity: granularity)
        let oldest = latest - granularity.seconds * TimeInterval(points - 1)
        var byBucket: [TimeInterval: SamplePoint] = [:]
        queue.sync {
            guard let db, !isClosed else { return }
            let sql = """
            SELECT bucket, COALESCE(SUM(bytes_in),0), COALESCE(SUM(bytes_out),0)
            FROM traffic_samples WHERE granularity=? AND bucket>=? AND bucket<=?
            GROUP BY bucket;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, Int64(granularity.rawValue))
            sqlite3_bind_int64(statement, 2, Int64(oldest))
            sqlite3_bind_int64(statement, 3, Int64(latest))
            while sqlite3_step(statement) == SQLITE_ROW {
                let bucket = TimeInterval(sqlite3_column_int64(statement, 0))
                let bytesIn = UInt64(max(0, sqlite3_column_int64(statement, 1)))
                let bytesOut = UInt64(max(0, sqlite3_column_int64(statement, 2)))
                byBucket[bucket] = SamplePoint(time: bucket, bytesIn: bytesIn, bytesOut: bytesOut)
            }
        }
        return (0..<points).reversed().compactMap { offset in
            let t = latest - granularity.seconds * TimeInterval(offset)
            return byBucket[t] ?? SamplePoint(time: t, bytesIn: 0, bytesOut: 0)
        }
    }

    /// 指定粒度、从 `since`（epoch 秒）到现在，每个应用的合计，按总量降序。
    /// 周视图查 30 分钟层、月视图查 2 小时层，行数都在几千以内。
    func topApps(_ granularity: Granularity, since: TimeInterval,
                 limit: Int = 8, now: Date = Date()) -> [AppEntry] {
        var result: [AppEntry] = []
        queue.sync {
            guard let db, !isClosed else { return }
            let sql = """
            SELECT app_key, app_name, COALESCE(SUM(bytes_in),0), COALESCE(SUM(bytes_out),0)
            FROM traffic_samples WHERE granularity=? AND bucket>=?
            GROUP BY app_key ORDER BY (bytes_in + bytes_out) DESC LIMIT ?;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, Int64(granularity.rawValue))
            sqlite3_bind_int64(statement, 2, Int64(since))
            sqlite3_bind_int(statement, 3, Int32(limit))
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

    /// 删除超过保留期的桶。
    func prune() {
        let now = Date().timeIntervalSince1970
        queue.async { [weak self] in
            guard let self, let db = self.db, !self.isClosed else { return }
            for granularity in Granularity.allCases {
                var statement: OpaquePointer?
                let sql = "DELETE FROM traffic_samples WHERE granularity=? AND bucket<?;"
                guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { continue }
                sqlite3_bind_int64(statement, 1, Int64(granularity.rawValue))
                sqlite3_bind_int64(statement, 2, Int64(now - granularity.retention))
                sqlite3_step(statement)
                sqlite3_finalize(statement)
            }
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

    /// 桶起始 epoch 秒：把时间向下取整到桶宽的整数倍。
    /// 5 分钟 / 30 分钟 / 2 小时彼此整除，任何时刻都只属于每层唯一一个桶。
    static func bucketStart(for date: Date, granularity: Granularity) -> TimeInterval {
        let t = date.timeIntervalSince1970
        let width = granularity.seconds
        return (t / width).rounded(.down) * width
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        guard let db else { return false }
        return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }
}

/// sqlite3_bind_text 需要「让 SQLite 自己拷贝字符串」的析构器。
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
