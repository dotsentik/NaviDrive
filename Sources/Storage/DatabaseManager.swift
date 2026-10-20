import Foundation
import SQLite3

enum DatabaseError: LocalizedError {
    case open(String)
    case prepare(String)
    case step(String)

    var errorDescription: String? {
        switch self {
        case .open(let m): "SQLite open: \(m)"
        case .prepare(let m): "SQLite prepare: \(m)"
        case .step(let m): "SQLite step: \(m)"
        }
    }
}

/// Потокобезопасная обёртка над системным SQLite3. Все обращения к соединению сериализуются через lock.
final class DatabaseManager: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    /// Отдельное read-only соединение для чтений интерфейса (сводка, список задач, маршруты, ссылки).
    /// В режиме WAL читатели не ждут пишущих: экран не стоит в очереди за обходом папок и планировщиком.
    private var readDB: OpaquePointer?
    private let readLock = NSLock()

    /// SQLITE_TRANSIENT: SQLite копирует привязанные строки.
    private var transient: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }

    let path: String

    init(path: String = AppSettings.supportDirectory.appendingPathComponent("navidrive_state.sqlite").path) throws {
        self.path = path
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw DatabaseError.open(message)
        }
        sqlite3_busy_timeout(db, 5_000)
        try execute("PRAGMA journal_mode=WAL;")
        try execute("PRAGMA synchronous=NORMAL;")
        try execute("""
            CREATE TABLE IF NOT EXISTS custom_routes (
                drive_id TEXT PRIMARY KEY,
                drive_name TEXT,
                local_path TEXT NOT NULL
            );
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS download_tasks (
                id TEXT PRIMARY KEY,
                drive_file_id TEXT NOT NULL,
                file_name TEXT NOT NULL,
                mime_type TEXT,
                expected_size INTEGER NOT NULL,
                downloaded_size INTEGER NOT NULL DEFAULT 0,
                md5_checksum TEXT,
                target_dir_path TEXT NOT NULL,
                status TEXT NOT NULL,
                retry_count INTEGER DEFAULT 0,
                last_error TEXT,
                updated_at INTEGER
            );
            """)
        try migrate()
        try createIndexes()

        let readFlags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path, &readDB, readFlags, nil) == SQLITE_OK {
            sqlite3_busy_timeout(readDB, 5_000)
        } else {
            // Без отдельного читателя всё продолжит работать через основное соединение.
            sqlite3_close_v2(readDB)
            readDB = nil
        }
    }

    /// Миграции схемы. Существующие строки не переписываются: новые колонки добавляются через ALTER TABLE.
    private func migrate() throws {
        // v2: класс задачи для умной очереди (0 — мелкий файл < 10 МБ, 1 — крупный, 2 — экспорт Google Docs).
        // Виртуальная генерируемая колонка вычисляется из уже сохранённых полей, поэтому старые задачи
        // сразу получают правильный класс без перезаписи данных.
        let columns = try query("PRAGMA table_xinfo(download_tasks)") { s in Self.text(s, 1) ?? "" }
        if !columns.contains("size_class") {
            try execute("""
                ALTER TABLE download_tasks ADD COLUMN size_class INTEGER GENERATED ALWAYS AS (
                    CASE
                        WHEN substr(mime_type, 1, 28) = 'application/vnd.google-apps.' THEN 2
                        WHEN expected_size < \(TaskSizeClass.smallFileThreshold) THEN 0
                        ELSE 1
                    END
                ) VIRTUAL;
                """)
        }
        // v3: resourceKey, проверка MD5, дата изменения из Drive, ожидание квоты Google.
        let addedColumns: [(String, String)] = [
            ("resource_key", "TEXT"),
            ("drive_modified_at", "INTEGER"),
            ("verified", "INTEGER NOT NULL DEFAULT 0"),
            ("checksum_failures", "INTEGER NOT NULL DEFAULT 0"),
            ("quota_attempts", "INTEGER NOT NULL DEFAULT 0"),
            ("next_attempt_at", "INTEGER"),
            // v4: задача, возобновлённая вручную, идёт в начало очереди.
            ("priority", "INTEGER NOT NULL DEFAULT 0"),
        ]
        for (name, definition) in addedColumns where !columns.contains(name) {
            try execute("ALTER TABLE download_tasks ADD COLUMN \(name) \(definition);")
        }

        // v5: очередь отправки в облако (существующие таблицы не меняются).
        try execute("""
            CREATE TABLE IF NOT EXISTS upload_tasks (
                id TEXT PRIMARY KEY,
                local_path TEXT NOT NULL,
                file_name TEXT NOT NULL,
                file_size INTEGER NOT NULL,
                local_modified_at INTEGER NOT NULL,
                parent_drive_id TEXT NOT NULL,
                session_uri TEXT,
                session_created_at INTEGER,
                uploaded_bytes INTEGER NOT NULL DEFAULT 0,
                status TEXT NOT NULL,
                retry_count INTEGER NOT NULL DEFAULT 0,
                last_error TEXT,
                drive_file_id TEXT,
                md5_checksum TEXT,
                updated_at INTEGER,
                parent_name TEXT,
                shared_drive_id TEXT,
                replace_file_id TEXT,
                error_kind TEXT,
                priority INTEGER NOT NULL DEFAULT 0
            );
            """)

        // Объекты, добавленные по ссылке (раздел «Добавленные по ссылке»).
        try execute("""
            CREATE TABLE IF NOT EXISTS linked_items (
                drive_id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                mime_type TEXT NOT NULL,
                resource_key TEXT,
                size INTEGER,
                drive_id_of_shared_drive TEXT,
                added_at INTEGER NOT NULL
            );
            """)

        // v6: несколько облаков. Колонка provider (существующие строки — 'googleDrive')
        // и первичные ключи по паре (provider, id).
        for table in ["download_tasks", "upload_tasks", "custom_routes"] {
            let names = try query("PRAGMA table_xinfo(\(table))") { s in Self.text(s, 1) ?? "" }
            if !names.contains("provider") {
                try execute("ALTER TABLE \(table) ADD COLUMN provider TEXT NOT NULL DEFAULT '\(CloudProviderKind.googleDrive.rawValue)';")
            }
        }
        // v7 (Dropbox): путь в облаке у задач скачивания, экспорт документов Dropbox в классе «экспорт»,
        // провайдер в «Добавленных по ссылке». Пересборка совмещена с v6 — таблица копируется один раз.
        let downloadColumns = try storedColumns("download_tasks")
        if try keyColumnCount("download_tasks") == 1 || !downloadColumns.contains("cloud_path") {
            try rebuild("download_tasks", schema: Self.downloadTasksSchema, columns: Self.downloadTasksStoredColumns)
        }
        if try keyColumnCount("upload_tasks") == 1 {
            try rebuild("upload_tasks", schema: Self.uploadTasksSchema, columns: Self.uploadTasksColumns)
        }
        // v8: правило конфликта имён у задачи отправки (Dropbox применяет его при upload_session/finish).
        if try !storedColumns("upload_tasks").contains("conflict_policy") {
            try execute("ALTER TABLE upload_tasks ADD COLUMN conflict_policy TEXT NOT NULL DEFAULT '\(UploadConflictPolicy.keepBoth.rawValue)';")
        }
        // v9: папки облака, внутри которых лежит файл задачи (kind 'd' — скачивание, 'u' — отправка).
        // По ним браузер показывает общий прогресс у строки папки. Строки удаляются вместе с задачей.
        try execute("""
            CREATE TABLE IF NOT EXISTS transfer_folders (
                kind TEXT NOT NULL,
                provider TEXT NOT NULL,
                folder_id TEXT NOT NULL,
                task_id TEXT NOT NULL,
                PRIMARY KEY (kind, provider, folder_id, task_id)
            ) WITHOUT ROWID;
            """)
        // v10: размер папки облака, посчитанный по запросу пользователя (обновляется только «Пересчитать»).
        try execute("""
            CREATE TABLE IF NOT EXISTS folder_sizes (
                provider TEXT NOT NULL,
                item_id TEXT NOT NULL,
                total_size INTEGER NOT NULL,
                file_count INTEGER NOT NULL,
                folder_count INTEGER NOT NULL,
                native_doc_count INTEGER NOT NULL,
                computed_at INTEGER NOT NULL,
                PRIMARY KEY (provider, item_id)
            ) WITHOUT ROWID;
            """)
        // v11: трафик облака за скользящие 24 часа по минутам (свои дневные лимиты Google Drive).
        try execute("DROP TABLE IF EXISTS daily_traffic;")
        try execute("""
            CREATE TABLE IF NOT EXISTS transfer_traffic (
                provider TEXT NOT NULL,
                direction TEXT NOT NULL,
                minute INTEGER NOT NULL,
                bytes INTEGER NOT NULL,
                PRIMARY KEY (provider, direction, minute)
            ) WITHOUT ROWID;
            """)
        // Ожидание квоты Google с повтором через часы заменено ожиданием лимита (limitReached).
        try execute("UPDATE download_tasks SET status = 'waiting_daily_limit' WHERE status = 'waiting_for' || '_quota';")
        if try keyColumnCount("custom_routes") == 1 {
            try rebuild("custom_routes", schema: Self.customRoutesSchema, columns: Self.customRoutesColumns)
        }
        if try keyColumnCount("linked_items") == 1 {
            try rebuild("linked_items", schema: Self.linkedItemsSchema, columns: Self.linkedItemsColumns)
        }
    }

    /// Индексы создаются после миграций: пересборка таблицы удаляет её индексы.
    private func createIndexes() throws {
        try execute("CREATE INDEX IF NOT EXISTS idx_tasks_status ON download_tasks(status);")
        try execute("CREATE INDEX IF NOT EXISTS idx_tasks_updated ON download_tasks(updated_at);")
        // Записи индекса с одинаковым ключом упорядочены по rowid, поэтому выборка
        // «WHERE status = 'queued' AND size_class = ? ORDER BY rowid» идёт без сортировки.
        try execute("CREATE INDEX IF NOT EXISTS idx_tasks_status_class ON download_tasks(status, size_class);")
        try execute("CREATE INDEX IF NOT EXISTS idx_tasks_target ON download_tasks(target_dir_path, file_name);")
        // Приоритетных задач единицы — частичный индекс почти ничего не стоит.
        try execute("CREATE INDEX IF NOT EXISTS idx_tasks_priority ON download_tasks(status, size_class) WHERE priority > 0;")
        // История и ошибки показываются «новые сверху» без сортировки всей таблицы.
        try execute("CREATE INDEX IF NOT EXISTS idx_tasks_status_updated ON download_tasks(status, updated_at);")
        try execute("CREATE INDEX IF NOT EXISTS idx_uploads_status ON upload_tasks(status, priority);")
        try execute("CREATE INDEX IF NOT EXISTS idx_uploads_status_updated ON upload_tasks(status, updated_at);")
        try execute("CREATE INDEX IF NOT EXISTS idx_uploads_local ON upload_tasks(local_path, parent_drive_id);")
        try execute("CREATE INDEX IF NOT EXISTS idx_tasks_file ON download_tasks(provider, drive_file_id);")
        try execute("CREATE INDEX IF NOT EXISTS idx_uploads_parent ON upload_tasks(provider, parent_drive_id);")
        try execute("CREATE INDEX IF NOT EXISTS idx_transfer_folders_task ON transfer_folders(kind, provider, task_id);")
        // Триггеры — после пересборок таблиц (пересборка удаляет и их).
        try execute("""
            CREATE TRIGGER IF NOT EXISTS trg_download_tasks_folders AFTER DELETE ON download_tasks BEGIN
                DELETE FROM transfer_folders WHERE kind = 'd' AND provider = old.provider AND task_id = old.id;
            END;
            """)
        try execute("""
            CREATE TRIGGER IF NOT EXISTS trg_upload_tasks_folders AFTER DELETE ON upload_tasks BEGIN
                DELETE FROM transfer_folders WHERE kind = 'u' AND provider = old.provider AND task_id = old.id;
            END;
            """)
    }

    // MARK: - v6: первичный ключ (provider, id)

    private static let downloadTasksStoredColumns = """
        id, drive_file_id, file_name, mime_type, expected_size, downloaded_size, md5_checksum, target_dir_path,
        status, retry_count, last_error, updated_at, resource_key, drive_modified_at, verified, checksum_failures,
        quota_attempts, next_attempt_at, priority, provider, cloud_path
        """

    /// Документы, которые скачиваются только экспортом (класс 2 умной очереди).
    private static let exportTypePrefixes = ["application/vnd.google-apps.", DropboxProvider.exportContentTypePrefix]

    private static let downloadTasksSchema = """
        id TEXT NOT NULL,
        drive_file_id TEXT NOT NULL,
        file_name TEXT NOT NULL,
        mime_type TEXT,
        expected_size INTEGER NOT NULL,
        downloaded_size INTEGER NOT NULL DEFAULT 0,
        md5_checksum TEXT,
        target_dir_path TEXT NOT NULL,
        status TEXT NOT NULL,
        retry_count INTEGER DEFAULT 0,
        last_error TEXT,
        updated_at INTEGER,
        resource_key TEXT,
        drive_modified_at INTEGER,
        verified INTEGER NOT NULL DEFAULT 0,
        checksum_failures INTEGER NOT NULL DEFAULT 0,
        quota_attempts INTEGER NOT NULL DEFAULT 0,
        next_attempt_at INTEGER,
        priority INTEGER NOT NULL DEFAULT 0,
        provider TEXT NOT NULL DEFAULT 'googleDrive',
        cloud_path TEXT,
        size_class INTEGER GENERATED ALWAYS AS (
            CASE
                WHEN \(exportTypePrefixes.map { "substr(mime_type, 1, \($0.count)) = '\($0)'" }.joined(separator: " OR ")) THEN 2
                WHEN expected_size < \(TaskSizeClass.smallFileThreshold) THEN 0
                ELSE 1
            END
        ) VIRTUAL,
        PRIMARY KEY (provider, id)
        """

    private static let uploadTasksColumns = """
        id, local_path, file_name, file_size, local_modified_at, parent_drive_id, session_uri, session_created_at,
        uploaded_bytes, status, retry_count, last_error, drive_file_id, md5_checksum, updated_at, parent_name,
        shared_drive_id, replace_file_id, error_kind, priority, provider
        """

    private static let uploadTasksSchema = """
        id TEXT NOT NULL,
        local_path TEXT NOT NULL,
        file_name TEXT NOT NULL,
        file_size INTEGER NOT NULL,
        local_modified_at INTEGER NOT NULL,
        parent_drive_id TEXT NOT NULL,
        session_uri TEXT,
        session_created_at INTEGER,
        uploaded_bytes INTEGER NOT NULL DEFAULT 0,
        status TEXT NOT NULL,
        retry_count INTEGER NOT NULL DEFAULT 0,
        last_error TEXT,
        drive_file_id TEXT,
        md5_checksum TEXT,
        updated_at INTEGER,
        parent_name TEXT,
        shared_drive_id TEXT,
        replace_file_id TEXT,
        error_kind TEXT,
        priority INTEGER NOT NULL DEFAULT 0,
        provider TEXT NOT NULL DEFAULT 'googleDrive',
        conflict_policy TEXT NOT NULL DEFAULT 'keep_both',
        PRIMARY KEY (provider, id)
        """

    private static let customRoutesColumns = "drive_id, drive_name, local_path, provider"

    private static let customRoutesSchema = """
        drive_id TEXT NOT NULL,
        drive_name TEXT,
        local_path TEXT NOT NULL,
        provider TEXT NOT NULL DEFAULT 'googleDrive',
        PRIMARY KEY (provider, drive_id)
        """

    private static let linkedItemsColumns = "drive_id, name, mime_type, resource_key, size, drive_id_of_shared_drive, added_at, provider"

    private static let linkedItemsSchema = """
        drive_id TEXT NOT NULL,
        name TEXT NOT NULL,
        mime_type TEXT NOT NULL,
        resource_key TEXT,
        size INTEGER,
        drive_id_of_shared_drive TEXT,
        added_at INTEGER NOT NULL,
        provider TEXT NOT NULL DEFAULT 'googleDrive',
        PRIMARY KEY (provider, drive_id)
        """

    private func keyColumnCount(_ table: String) throws -> Int {
        try query("PRAGMA table_info(\(table))") { s in sqlite3_column_int(s, 5) }.filter { $0 > 0 }.count
    }

    /// Обычные (не генерируемые) колонки таблицы.
    private func storedColumns(_ table: String) throws -> Set<String> {
        Set(try query("PRAGMA table_xinfo(\(table))") { s in
            sqlite3_column_int(s, 6) == 0 ? Self.text(s, 1) : nil
        }.compactMap { $0 })
    }

    /// Первичный ключ и генерируемые колонки SQLite нельзя изменить через ALTER TABLE, поэтому таблица
    /// пересобирается одной транзакцией: новая таблица, копия всех строк с прежними rowid
    /// (порядок очереди сохраняется), удаление старой, переименование. Копируются колонки, которые
    /// есть в старой таблице; новые получают значения по умолчанию. При ошибке — откат без потерь.
    private func rebuild(_ table: String, schema: String, columns: String) throws {
        let existing = try storedColumns(table)
        let copied = columns.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter(existing.contains).joined(separator: ", ")
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try execute("DROP TABLE IF EXISTS \(table)_rebuild;")
            try execute("CREATE TABLE \(table)_rebuild (\(schema));")
            try execute("INSERT INTO \(table)_rebuild (rowid, \(copied)) SELECT rowid, \(copied) FROM \(table);")
            try execute("DROP TABLE \(table);")
            try execute("ALTER TABLE \(table)_rebuild RENAME TO \(table);")
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    deinit {
        sqlite3_close_v2(readDB)
        sqlite3_close_v2(db)
    }

    // MARK: - Low level

    private var errorMessage: String { String(cString: sqlite3_errmsg(db)) }
    private static func errorMessage(_ handle: OpaquePointer?) -> String { String(cString: sqlite3_errmsg(handle)) }

    private func execute(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(error)
            throw DatabaseError.step(message)
        }
    }

    private enum Value {
        case text(String?)
        case int(Int64)
    }

    private func prepare(_ sql: String, _ values: [Value], on handle: OpaquePointer? = nil) throws -> OpaquePointer {
        let connection = handle ?? db
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DatabaseError.prepare(Self.errorMessage(connection))
        }
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case .text(let string):
                if let string {
                    sqlite3_bind_text(statement, position, string, -1, transient)
                } else {
                    sqlite3_bind_null(statement, position)
                }
            case .int(let number):
                sqlite3_bind_int64(statement, position, number)
            }
        }
        return statement
    }

    @discardableResult
    private func run(_ sql: String, _ values: [Value] = []) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        let rc = sqlite3_step(statement)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw DatabaseError.step(errorMessage) }
        return Int(sqlite3_changes(db))
    }

    /// - Parameter reader: выполнить на read-only соединении (только для чтений вне транзакций записи).
    private func query<T>(_ sql: String, _ values: [Value] = [], reader: Bool = false,
                          map: (OpaquePointer) -> T) throws -> [T] {
        let useReader = reader && readDB != nil
        let activeLock: NSLocking = useReader ? readLock : lock
        let handle = useReader ? readDB : db
        activeLock.lock(); defer { activeLock.unlock() }
        let statement = try prepare(sql, values, on: handle)
        defer { sqlite3_finalize(statement) }
        var rows: [T] = []
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_ROW {
                rows.append(map(statement))
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw DatabaseError.step(Self.errorMessage(handle))
            }
        }
        return rows
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: cString)
    }

    private static var now: Int64 { Int64(Date().timeIntervalSince1970) }

    // MARK: - Custom routes

    private static func provider(_ s: OpaquePointer, _ column: Int32) -> CloudProviderKind {
        text(s, column).flatMap(CloudProviderKind.init(rawValue:)) ?? .googleDrive
    }

    func allRoutes() -> [CustomRoute] {
        (try? query("SELECT drive_id, drive_name, local_path, provider FROM custom_routes ORDER BY drive_name COLLATE NOCASE", reader: true) { s in
            CustomRoute(provider: Self.provider(s, 3), driveId: Self.text(s, 0) ?? "", driveName: Self.text(s, 1) ?? "",
                        localPath: Self.text(s, 2) ?? "")
        }) ?? []
    }

    func setRoute(provider: CloudProviderKind, driveId: String, driveName: String, localPath: String) throws {
        try run("""
            INSERT INTO custom_routes (provider, drive_id, drive_name, local_path) VALUES (?, ?, ?, ?)
            ON CONFLICT(provider, drive_id) DO UPDATE SET drive_name = excluded.drive_name, local_path = excluded.local_path
            """, [.text(provider.rawValue), .text(driveId), .text(driveName), .text(localPath)])
    }

    func deleteRoute(provider: CloudProviderKind, driveId: String) throws {
        try run("DELETE FROM custom_routes WHERE provider = ? AND drive_id = ?", [.text(provider.rawValue), .text(driveId)])
    }

    // MARK: - Linked items

    func linkedItems() -> [LinkedItem] {
        (try? query("""
            SELECT drive_id, name, mime_type, resource_key, size, drive_id_of_shared_drive, added_at, provider
            FROM linked_items ORDER BY added_at DESC
            """, reader: true) { s in
            LinkedItem(provider: Self.provider(s, 7), driveId: Self.text(s, 0) ?? "", name: Self.text(s, 1) ?? "", mimeType: Self.text(s, 2) ?? "",
                       resourceKey: Self.text(s, 3), size: Self.optionalInt(s, 4),
                       sharedDriveId: Self.text(s, 5), addedAt: sqlite3_column_int64(s, 6))
        }) ?? []
    }

    func saveLinked(_ item: LinkedItem) throws {
        try run("""
            INSERT INTO linked_items (drive_id, name, mime_type, resource_key, size, drive_id_of_shared_drive, added_at, provider)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(provider, drive_id) DO UPDATE SET name = excluded.name, mime_type = excluded.mime_type,
                resource_key = COALESCE(excluded.resource_key, linked_items.resource_key),
                size = COALESCE(excluded.size, linked_items.size),
                drive_id_of_shared_drive = excluded.drive_id_of_shared_drive
            """, [.text(item.driveId), .text(item.name), .text(item.mimeType), .text(item.resourceKey),
                  item.size.map { .int($0) } ?? .text(nil), .text(item.sharedDriveId), .int(item.addedAt),
                  .text(item.provider.rawValue)])
    }

    func deleteLinked(provider: CloudProviderKind, driveId: String) throws {
        try run("DELETE FROM linked_items WHERE provider = ? AND drive_id = ?", [.text(provider.rawValue), .text(driveId)])
    }

    // MARK: - Download tasks

    private static let taskColumns = """
        id, drive_file_id, file_name, mime_type, expected_size, downloaded_size, md5_checksum,
        target_dir_path, status, retry_count, last_error, updated_at,
        resource_key, drive_modified_at, verified, checksum_failures, quota_attempts, next_attempt_at, provider, cloud_path
        """

    private static func optionalInt(_ s: OpaquePointer, _ column: Int32) -> Int64? {
        sqlite3_column_type(s, column) == SQLITE_NULL ? nil : sqlite3_column_int64(s, column)
    }

    private static func task(from s: OpaquePointer) -> DownloadTask {
        DownloadTask(
            id: text(s, 0) ?? "",
            driveFileId: text(s, 1) ?? "",
            fileName: text(s, 2) ?? "",
            mimeType: text(s, 3),
            expectedSize: sqlite3_column_int64(s, 4),
            downloadedSize: sqlite3_column_int64(s, 5),
            checksum: text(s, 6),
            targetDirPath: text(s, 7) ?? "",
            status: TaskStatus(rawValue: text(s, 8) ?? "") ?? .queued,
            retryCount: Int(sqlite3_column_int64(s, 9)),
            lastError: text(s, 10),
            updatedAt: sqlite3_column_int64(s, 11),
            resourceKey: text(s, 12),
            driveModifiedAt: optionalInt(s, 13),
            verified: sqlite3_column_int64(s, 14) != 0,
            checksumFailures: Int(sqlite3_column_int64(s, 15)),
            quotaAttempts: Int(sqlite3_column_int64(s, 16)),
            nextAttemptAt: optionalInt(s, 17),
            provider: provider(s, 18),
            cloudPath: text(s, 19)
        )
    }

    /// Постановка в очередь с проверкой диска: файлы, которые уже лежат на месте с нужным размером,
    /// не скачиваются заново, а сразу помечаются `completed`.
    func enqueue(_ tasks: [DownloadTask]) throws -> (added: Int, alreadyDownloaded: Int, forbidden: Int) {
        var alreadyDownloaded = 0
        var forbidden = 0
        let prepared = tasks.map { task -> DownloadTask in
            if task.status == .failed {
                forbidden += 1
                return task
            }
            guard task.isAlreadyDownloaded else { return task }
            alreadyDownloaded += 1
            var done = task
            done.status = .completed
            done.downloadedSize = task.expectedSize
            return done
        }
        try insertTasks(prepared)
        return (tasks.count - alreadyDownloaded - forbidden, alreadyDownloaded, forbidden)
    }

    /// Пакетная вставка задач одной транзакцией. Повторно добавленные задачи (кроме активных)
    /// получают статус из `task.status` (обычно `queued`).
    func insertTasks(_ tasks: [DownloadTask]) throws {
        guard !tasks.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let sql = """
                INSERT INTO download_tasks (\(Self.taskColumns))
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?, 0, 0, NULL, ?, ?)
                ON CONFLICT(provider, id) DO UPDATE SET
                    file_name = excluded.file_name,
                    mime_type = excluded.mime_type,
                    expected_size = excluded.expected_size,
                    md5_checksum = excluded.md5_checksum,
                    downloaded_size = CASE WHEN excluded.status = 'completed'
                        THEN excluded.downloaded_size ELSE download_tasks.downloaded_size END,
                    status = CASE WHEN download_tasks.status = 'downloading' THEN 'downloading' ELSE excluded.status END,
                    retry_count = 0,
                    last_error = excluded.last_error,
                    resource_key = COALESCE(excluded.resource_key, download_tasks.resource_key),
                    drive_modified_at = excluded.drive_modified_at,
                    verified = CASE WHEN excluded.status = 'completed' THEN download_tasks.verified ELSE 0 END,
                    checksum_failures = 0,
                    quota_attempts = 0,
                    next_attempt_at = NULL,
                    cloud_path = excluded.cloud_path,
                    updated_at = excluded.updated_at
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw DatabaseError.prepare(errorMessage)
            }
            defer { sqlite3_finalize(statement) }
            for task in tasks {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                sqlite3_bind_text(statement, 1, task.id, -1, transient)
                sqlite3_bind_text(statement, 2, task.driveFileId, -1, transient)
                sqlite3_bind_text(statement, 3, task.fileName, -1, transient)
                if let mime = task.mimeType { sqlite3_bind_text(statement, 4, mime, -1, transient) } else { sqlite3_bind_null(statement, 4) }
                sqlite3_bind_int64(statement, 5, task.expectedSize)
                sqlite3_bind_int64(statement, 6, task.downloadedSize)
                if let checksum = task.checksum { sqlite3_bind_text(statement, 7, checksum, -1, transient) } else { sqlite3_bind_null(statement, 7) }
                sqlite3_bind_text(statement, 8, task.targetDirPath, -1, transient)
                sqlite3_bind_text(statement, 9, task.status.rawValue, -1, transient)
                if let error = task.lastError { sqlite3_bind_text(statement, 10, error, -1, transient) } else { sqlite3_bind_null(statement, 10) }
                sqlite3_bind_int64(statement, 11, task.updatedAt)
                if let key = task.resourceKey { sqlite3_bind_text(statement, 12, key, -1, transient) } else { sqlite3_bind_null(statement, 12) }
                if let modified = task.driveModifiedAt { sqlite3_bind_int64(statement, 13, modified) } else { sqlite3_bind_null(statement, 13) }
                sqlite3_bind_int64(statement, 14, task.verified ? 1 : 0)
                sqlite3_bind_text(statement, 15, task.provider.rawValue, -1, transient)
                if let path = task.cloudPath { sqlite3_bind_text(statement, 16, path, -1, transient) } else { sqlite3_bind_null(statement, 16) }
                guard sqlite3_step(statement) == SQLITE_DONE else { throw DatabaseError.step(errorMessage) }
                try insertTransferFolders(kind: "d", provider: task.provider, taskId: task.id, folderIds: task.folderIds)
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    func task(id: String) -> DownloadTask? {
        try? query("SELECT \(Self.taskColumns) FROM download_tasks WHERE id = ?", [.text(id)], map: Self.task).first
    }

    /// Условие «задача одного из облаков» (облака без входа в очередь не берутся).
    private static func providerFilter(_ providers: Set<CloudProviderKind>) -> (sql: String, values: [Value]) {
        let sorted = providers.map(\.rawValue).sorted()
        guard !sorted.isEmpty else { return ("0", []) }
        return ("provider IN (\(sorted.map { _ in "?" }.joined(separator: ",")))", sorted.map { .text($0) })
    }

    /// rowid первой задачи в очереди для каждого класса (отсутствие ключа — класс пуст).
    /// - Parameter budget: свой лимит облака — только задачи, которые помещаются в остаток.
    func queueHeads(providers: Set<CloudProviderKind>, budget: TransferBudget? = nil) -> [TaskSizeClass: Int64] {
        var heads: [TaskSizeClass: Int64] = [:]
        let filter = Self.providerFilter(providers)
        let budgetFilter = Self.downloadBudgetFilter(budget)
        for sizeClass in TaskSizeClass.allCases {
            let rowid = try? query(
                "SELECT rowid FROM download_tasks WHERE status = 'queued' AND size_class = ? AND \(filter.sql) AND \(budgetFilter.sql) ORDER BY rowid LIMIT 1",
                [.int(Int64(sizeClass.rawValue))] + filter.values + budgetFilter.values) { s in sqlite3_column_int64(s, 0) }.first
            if let rowid { heads[sizeClass] = rowid }
        }
        return heads
    }

    /// Атомарно забирает следующую задачу класса: в одной транзакции переводит `queued → downloading`.
    /// Условие `AND status = 'queued'` гарантирует, что одна и та же задача не будет запущена дважды.
    func claimNext(sizeClass: TaskSizeClass, providers: Set<CloudProviderKind>, budget: TransferBudget? = nil) -> DownloadTask? {
        lock.lock(); defer { lock.unlock() }
        let filter = Self.providerFilter(providers)
        let budgetFilter = Self.downloadBudgetFilter(budget)
        guard (try? execute("BEGIN IMMEDIATE TRANSACTION;")) != nil else { return nil }
        let task = (try? query(
            "SELECT \(Self.taskColumns) FROM download_tasks WHERE status = 'queued' AND size_class = ? AND \(filter.sql) AND \(budgetFilter.sql) ORDER BY rowid LIMIT 1",
            [.int(Int64(sizeClass.rawValue))] + filter.values + budgetFilter.values, map: Self.task))?.first
        guard let task else {
            _ = try? execute("COMMIT;")
            return nil
        }
        let changed = (try? run(
            "UPDATE download_tasks SET status = 'downloading', priority = 0, last_error = NULL, updated_at = ? WHERE id = ? AND status = 'queued'",
            [.int(Self.now), .text(task.id)])) ?? 0
        guard (try? execute("COMMIT;")) != nil, changed == 1 else {
            _ = try? execute("ROLLBACK;")
            return nil
        }
        var claimed = task
        claimed.status = .downloading
        return claimed
    }

    /// Атомарно забирает задачу, возобновлённую вручную (priority > 0), раньше обычной очереди.
    /// - Parameter allowExport: можно ли взять экспорт Google Docs (лимит 2 одновременных).
    func claimNextPrioritized(allowExport: Bool, providers: Set<CloudProviderKind>, budget: TransferBudget? = nil) -> DownloadTask? {
        lock.lock(); defer { lock.unlock() }
        let filter = Self.providerFilter(providers)
        let budgetFilter = Self.downloadBudgetFilter(budget)
        guard (try? execute("BEGIN IMMEDIATE TRANSACTION;")) != nil else { return nil }
        let exportFilter = allowExport ? "" : "AND size_class <> \(TaskSizeClass.export.rawValue)"
        let task = (try? query(
            "SELECT \(Self.taskColumns) FROM download_tasks WHERE status = 'queued' AND priority > 0 \(exportFilter) AND \(filter.sql) AND \(budgetFilter.sql) ORDER BY rowid LIMIT 1",
            filter.values + budgetFilter.values, map: Self.task))?.first
        guard let task else {
            _ = try? execute("COMMIT;")
            return nil
        }
        let changed = (try? run(
            "UPDATE download_tasks SET status = 'downloading', priority = 0, last_error = NULL, updated_at = ? WHERE id = ? AND status = 'queued'",
            [.int(Self.now), .text(task.id)])) ?? 0
        guard (try? execute("COMMIT;")) != nil, changed == 1 else {
            _ = try? execute("ROLLBACK;")
            return nil
        }
        var claimed = task
        claimed.status = .downloading
        return claimed
    }

    /// «Возобновить»: в очередь с приоритетом. Докачка продолжится с размера .gdrive.part.
    func resume(id: String) {
        _ = try? run("""
            UPDATE download_tasks SET status = 'queued', priority = 1, retry_count = 0, checksum_failures = 0,
                last_error = NULL, next_attempt_at = NULL, updated_at = ?
            WHERE id = ? AND status NOT IN ('downloading', 'verifying', 'completed')
            """, [.int(Self.now), .text(id)])
    }

    /// «Возобновить все» в секции «На паузе»: и вручную приостановленные, и после общей паузы (с приоритетом).
    @discardableResult
    func resumeAllPaused() -> Int {
        (try? run("UPDATE download_tasks SET status = 'queued', priority = 1, last_error = NULL, updated_at = ? WHERE status IN ('paused', 'paused_all')",
                  [.int(Self.now)])) ?? 0
    }

    /// Общая пауза: идущие и ожидающие задачи → paused_all одной операцией.
    func pauseAll() {
        let from = TaskStatus.pausable.map { "'\($0.rawValue)'" }.joined(separator: ", ")
        _ = try? run("UPDATE download_tasks SET status = 'paused_all', last_error = NULL, updated_at = ? WHERE status IN (\(from))",
                     [.int(Self.now)])
    }

    /// Снять общую паузу: только задачи paused_all, в прежнем порядке очереди; вручную приостановленные остаются.
    @discardableResult
    func resumePausedAll() -> Int {
        (try? run("UPDATE download_tasks SET status = 'queued', updated_at = ? WHERE status = 'paused_all'",
                  [.int(Self.now)])) ?? 0
    }

    /// Задачи одного статуса в порядке индекса (без сортировки всей таблицы).
    /// - Parameter newestFirst: история/ошибки — новые сверху; очередь — в порядке постановки.
    func tasks(status: TaskStatus, newestFirst: Bool, limit: Int) -> [DownloadTask] {
        let order = newestFirst ? "updated_at DESC" : "rowid ASC"
        return (try? query(
            "SELECT \(Self.taskColumns) FROM download_tasks WHERE status = ? ORDER BY \(order) LIMIT ?",
            [.text(status.rawValue), .int(Int64(limit))], reader: true, map: Self.task)) ?? []
    }

    /// Есть ли в той же папке задача с тем же именем файла, но для другого объекта облака.
    func fileNameTaken(targetDir: String, fileName: String, except provider: CloudProviderKind, fileId: String) -> Bool {
        let rows = (try? query("""
            SELECT 1 FROM download_tasks WHERE target_dir_path = ? AND file_name = ?
                AND NOT (provider = ? AND drive_file_id = ?) AND status <> 'cancelled' LIMIT 1
            """, [.text(targetDir), .text(fileName), .text(provider.rawValue), .text(fileId)]) { _ in true }) ?? []
        return !rows.isEmpty
    }

    /// Пакетная запись прогресса одной транзакцией.
    func updateProgressBatch(_ progress: [String: Int64]) {
        guard !progress.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        guard (try? execute("BEGIN IMMEDIATE TRANSACTION;")) != nil else { return }
        let now = Self.now
        for (id, bytes) in progress {
            _ = try? run("UPDATE download_tasks SET downloaded_size = ?, updated_at = ? WHERE id = ? AND status <> 'completed'",
                         [.int(bytes), .int(now), .text(id)])
        }
        if (try? execute("COMMIT;")) == nil { _ = try? execute("ROLLBACK;") }
    }

    /// Переводит в `waiting_for_volume` все задачи очереди на отключённом томе, чтобы они не занимали слоты.
    func markWaitingForVolume(volumeRoot: String, message: String) {
        let escaped = volumeRoot.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        _ = try? run("""
            UPDATE download_tasks SET status = 'waiting_for_volume', last_error = ?, updated_at = ?
            WHERE status = 'queued' AND (target_dir_path = ? OR target_dir_path LIKE ? ESCAPE '\\')
            """, [.text(message), .int(Self.now), .text(volumeRoot), .text(escaped + "/%")])
    }

    func updateStatus(id: String, status: TaskStatus, error: String? = nil) {
        _ = try? run("UPDATE download_tasks SET status = ?, last_error = ?, updated_at = ? WHERE id = ?",
                 [.text(status.rawValue), .text(error), .int(Self.now), .text(id)])
    }

    func updateProgress(id: String, downloaded: Int64) {
        _ = try? run("UPDATE download_tasks SET downloaded_size = ?, updated_at = ? WHERE id = ?",
                 [.int(downloaded), .int(Self.now), .text(id)])
    }

    func markCompleted(id: String, size: Int64, verified: Bool = false) {
        _ = try? run("""
            UPDATE download_tasks SET status = 'completed', downloaded_size = ?, verified = ?, checksum_failures = 0,
                last_error = NULL, updated_at = ? WHERE id = ?
            """, [.int(size), .int(verified ? 1 : 0), .int(Self.now), .text(id)])
    }

    /// Несовпадение MD5: файл удалён, задача либо снова в очереди, либо (после 2 раз подряд) в ошибках.
    func markChecksumMismatch(id: String, failures: Int, error: String, giveUp: Bool) {
        _ = try? run("""
            UPDATE download_tasks SET status = ?, downloaded_size = 0, checksum_failures = ?, verified = 0,
                last_error = ?, updated_at = ? WHERE id = ?
            """, [.text(giveUp ? TaskStatus.failed.rawValue : TaskStatus.queued.rawValue),
                  .int(Int64(failures)), .text(error), .int(Self.now), .text(id)])
    }

    /// - Parameter nextAttemptAt: когда будет следующая попытка (для обратного отсчёта в статусе).
    func recordRetry(id: String, retryCount: Int, error: String, nextAttemptAt: Int64? = nil) {
        _ = try? run("UPDATE download_tasks SET retry_count = ?, last_error = ?, next_attempt_at = ?, updated_at = ? WHERE id = ?",
                 [.int(Int64(retryCount)), .text(error), nextAttemptAt.map { .int($0) } ?? .text(nil), .int(Self.now), .text(id)])
    }

    /// Пояснение к идущему скачиванию без изменения счётчика повторов (например, «начато заново»).
    func setLastError(id: String, error: String) {
        _ = try? run("UPDATE download_tasks SET last_error = ?, next_attempt_at = NULL, updated_at = ? WHERE id = ?",
                 [.text(error), .int(Self.now), .text(id)])
    }

    /// Переводит задачи из одних статусов в другой (например, после перезапуска приложения).
    @discardableResult
    /// - Parameter provider: только задачи этого облака (nil — всех).
    func moveStatuses(_ from: [TaskStatus], to: TaskStatus, provider: CloudProviderKind? = nil) -> Int {
        guard !from.isEmpty else { return 0 }
        let placeholders = from.map { _ in "?" }.joined(separator: ",")
        var values: [Value] = [.text(to.rawValue), .int(Self.now)] + from.map { .text($0.rawValue) }
        var sql = "UPDATE download_tasks SET status = ?, updated_at = ? WHERE status IN (\(placeholders))"
        if let provider {
            sql += " AND provider = ?"
            values.append(.text(provider.rawValue))
        }
        return (try? run(sql, values)) ?? 0
    }

    /// Корневые пути томов (`/Volumes/<Name>`), задачи на которых ждут подключения диска.
    func volumesAwaitingMount() -> Set<String> {
        let dirs = (try? query("SELECT DISTINCT target_dir_path FROM download_tasks WHERE status = 'waiting_for_volume'") { s in
            Self.text(s, 0) ?? ""
        }) ?? []
        return Set(dirs.compactMap { dir in
            let parts = dir.split(separator: "/", omittingEmptySubsequences: true)
            guard parts.count >= 2, parts[0] == "Volumes" else { return nil }
            return "/Volumes/\(parts[1])"
        })
    }

    func requeueWaitingForVolume(volumeRoot: String) {
        let escaped = volumeRoot.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        _ = try? run("""
            UPDATE download_tasks SET status = 'queued', last_error = NULL, updated_at = ?
            WHERE status = 'waiting_for_volume' AND (target_dir_path = ? OR target_dir_path LIKE ? ESCAPE '\\')
            """, [.int(Self.now), .text(volumeRoot), .text(escaped + "/%")])
    }

    // MARK: - Диски

    /// Корень тома для пути задачи: `/Volumes/<Name>` для внешних томов, иначе «/» (системный диск).
    private static let volumeRootSQL = """
        CASE WHEN target_dir_path LIKE '/Volumes/%' \
        THEN substr(target_dir_path, 1, 8 + instr(substr(target_dir_path, 10) || '/', '/')) ELSE '/' END
        """

    /// Условие «задача на томе `root`» (`root` — значение `PathResolver.volumeKey`).
    private static func volumeFilter(_ root: String) -> (sql: String, values: [Value]) {
        if root == "/" { return ("target_dir_path NOT LIKE '/Volumes/%'", []) }
        let escaped = root.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        return ("(target_dir_path = ? OR target_dir_path LIKE ? ESCAPE '\\')", [.text(root), .text(escaped + "/%")])
    }

    /// Сколько осталось скачать на каждый том и сколько файлов качается туда прямо сейчас.
    func volumeQueueUsage() -> [String: VolumeQueueUsage] {
        let rows = (try? query("""
            SELECT \(Self.volumeRootSQL) AS root,
                SUM(MAX(expected_size - downloaded_size, 0)), SUM(status = 'downloading')
            FROM download_tasks
            WHERE status IN ('queued', 'downloading', 'paused', 'paused_all', 'waiting_for_volume', 'waiting_for_network',
                             'waiting_daily_limit', 'waiting_for_space')
            GROUP BY root
            """, reader: true) { s in
            (Self.text(s, 0) ?? "/", sqlite3_column_int64(s, 1), Int(sqlite3_column_int64(s, 2)))
        }) ?? []
        var result: [String: VolumeQueueUsage] = [:]
        for (root, remaining, downloading) in rows {
            result[root] = VolumeQueueUsage(remainingBytes: remaining, downloadingCount: downloading)
        }
        return result
    }

    /// Тома, на которых есть задачи, ждущие свободного места.
    func volumesAwaitingSpace() -> Set<String> {
        Set((try? query("SELECT DISTINCT \(Self.volumeRootSQL) FROM download_tasks WHERE status = 'waiting_for_space'") { s in
            Self.text(s, 0) ?? "/"
        }) ?? [])
    }

    /// Возвращает в очередь ждущие места задачи тома, которым хватает `availableBytes` (в порядке очереди).
    @discardableResult
    func requeueWaitingForSpace(volumeRoot: String, availableBytes: Int64) -> Int {
        let filter = Self.volumeFilter(volumeRoot)
        let candidates = (try? query("""
            SELECT id, MAX(expected_size - downloaded_size, 0) FROM download_tasks
            WHERE status = 'waiting_for_space' AND \(filter.sql) ORDER BY rowid
            """, filter.values) { s in (Self.text(s, 0) ?? "", sqlite3_column_int64(s, 1)) }) ?? []
        var budget = availableBytes
        var ids: [String] = []
        for (id, remaining) in candidates where remaining <= budget {
            budget -= remaining
            ids.append(id)
        }
        for id in ids {
            _ = try? run("UPDATE download_tasks SET status = 'queued', last_error = NULL, updated_at = ? WHERE id = ? AND status = 'waiting_for_space'",
                         [.int(Self.now), .text(id)])
        }
        return ids.count
    }

    /// Ставит на паузу все незапущенные задачи тома (перед извлечением диска).
    func pauseTasks(volumeRoot: String) {
        let filter = Self.volumeFilter(volumeRoot)
        _ = try? run("""
            UPDATE download_tasks SET status = 'paused', updated_at = ?
            WHERE status IN ('queued', 'waiting_for_volume', 'waiting_for_network', 'waiting_daily_limit', 'waiting_for_space')
                AND \(filter.sql)
            """, [.int(Self.now)] + filter.values)
    }

    func retryFailed() {
        _ = try? run("UPDATE download_tasks SET status = 'queued', retry_count = 0, last_error = NULL, updated_at = ? WHERE status = 'failed'",
                 [.int(Self.now)])
    }

    func deleteTasks(statuses: [TaskStatus]) {
        let placeholders = statuses.map { _ in "?" }.joined(separator: ",")
        _ = try? run("DELETE FROM download_tasks WHERE status IN (\(placeholders))", statuses.map { .text($0.rawValue) })
    }

    func tasks(statuses: [TaskStatus], limit: Int = 500, provider: CloudProviderKind? = nil) -> [DownloadTask] {
        let placeholders = statuses.map { _ in "?" }.joined(separator: ",")
        let order = statuses.allSatisfy({ TaskStatus.pending.contains($0) }) ? "rowid ASC" : "updated_at DESC"
        let providerSQL = provider == nil ? "" : "AND provider = ?"
        let sql = """
            SELECT \(Self.taskColumns) FROM download_tasks
            WHERE status IN (\(placeholders)) \(providerSQL)
            ORDER BY CASE status WHEN 'downloading' THEN 0 ELSE 1 END, \(order)
            LIMIT ?
            """
        let values: [Value] = statuses.map { .text($0.rawValue) } + (provider.map { [.text($0.rawValue)] } ?? [])
            + [.int(Int64(limit))]
        return (try? query(sql, values, reader: true, map: Self.task)) ?? []
    }

    /// Суммарная статистика очереди (по всем задачам, кроме отменённых).
    func totals() -> QueueTotals {
        var totals = QueueTotals()
        let rows = (try? query("""
            SELECT status, COUNT(*), SUM(expected_size), SUM(MIN(downloaded_size, CASE WHEN expected_size > 0 THEN expected_size ELSE downloaded_size END))
            FROM download_tasks GROUP BY status
            """, reader: true) { s in
            (Self.text(s, 0) ?? "", Int(sqlite3_column_int64(s, 1)), sqlite3_column_int64(s, 2), sqlite3_column_int64(s, 3))
        }) ?? []
        for (rawStatus, count, expected, downloaded) in rows {
            guard let status = TaskStatus(rawValue: rawStatus) else { continue }
            totals.countsByStatus[status] = count
            totals.bytesByStatus[status] = expected
            guard status != .cancelled else { continue }
            totals.taskCount += count
            if TaskStatus.pending.contains(status) { totals.pendingCount += count }
            totals.expectedBytes += expected
            totals.downloadedBytes += status == .completed ? max(expected, downloaded) : downloaded
        }
        totals.byProvider = downloadProgressByProvider()
        if (totals.countsByStatus[.waitingForVolume] ?? 0) > 0 {
            totals.volumesAwaitingMount = downloadCountsByVolume(status: .waitingForVolume)
        }
        if (totals.countsByStatus[.waitingForSpace] ?? 0) > 0 {
            totals.volumesAwaitingSpace = downloadCountsByVolume(status: .waitingForSpace)
        }
        return totals
    }
}

// MARK: - Upload tasks

extension DatabaseManager {
    private static let uploadColumns = """
        id, local_path, file_name, file_size, local_modified_at, parent_drive_id, parent_name, shared_drive_id,
        replace_file_id, session_uri, session_created_at, uploaded_bytes, status, retry_count, last_error,
        error_kind, drive_file_id, md5_checksum, updated_at, provider, conflict_policy
        """

    private static func upload(_ s: OpaquePointer) -> UploadTask {
        UploadTask(
            id: text(s, 0) ?? "", localPath: text(s, 1) ?? "", fileName: text(s, 2) ?? "",
            fileSize: sqlite3_column_int64(s, 3), localModifiedAt: sqlite3_column_int64(s, 4),
            parentDriveId: text(s, 5) ?? "root", parentName: text(s, 6) ?? "", sharedDriveId: text(s, 7),
            replaceFileId: text(s, 8), sessionURI: text(s, 9), sessionCreatedAt: optionalInt(s, 10),
            uploadedBytes: sqlite3_column_int64(s, 11), status: UploadStatus(rawValue: text(s, 12) ?? "") ?? .failed,
            retryCount: Int(sqlite3_column_int64(s, 13)), lastError: text(s, 14),
            errorKind: text(s, 15).flatMap(UploadErrorKind.init(rawValue:)), driveFileId: text(s, 16),
            checksum: text(s, 17), updatedAt: sqlite3_column_int64(s, 18), provider: provider(s, 19),
            conflictPolicy: text(s, 20).flatMap(UploadConflictPolicy.init(rawValue:)) ?? .keepBoth)
    }

    /// Пакетная постановка в очередь одной транзакцией. Файл, который уже ждёт отправки
    /// в ту же папку, повторно не добавляется.
    func insertUploads(_ tasks: [UploadTask]) throws -> (added: Int, alreadyQueued: Int) {
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        var added = 0, duplicates = 0
        do {
            for task in tasks {
                let exists = try query("""
                    SELECT 1 FROM upload_tasks WHERE local_path = ? AND parent_drive_id = ? AND file_name = ? AND provider = ?
                        AND status NOT IN ('completed', 'cancelled', 'failed') LIMIT 1
                    """, [.text(task.localPath), .text(task.parentDriveId), .text(task.fileName),
                          .text(task.provider.rawValue)]) { _ in true }
                if !exists.isEmpty { duplicates += 1; continue }
                try run("""
                    INSERT INTO upload_tasks (id, local_path, file_name, file_size, local_modified_at, parent_drive_id,
                        parent_name, shared_drive_id, replace_file_id, uploaded_bytes, status, updated_at, provider,
                        conflict_policy)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 'queued', ?, ?, ?)
                    """, [.text(task.id), .text(task.localPath), .text(task.fileName), .int(task.fileSize),
                          .int(task.localModifiedAt), .text(task.parentDriveId), .text(task.parentName),
                          .text(task.sharedDriveId), .text(task.replaceFileId), .int(Self.now),
                          .text(task.provider.rawValue), .text(task.conflictPolicy.rawValue)])
                try insertTransferFolders(kind: "u", provider: task.provider, taskId: task.id, folderIds: task.folderIds)
                added += 1
            }
            try execute("COMMIT;")
        } catch {
            _ = try? execute("ROLLBACK;")
            throw error
        }
        return (added, duplicates)
    }

    /// Атомарно забирает следующую задачу (сначала возобновлённые вручную, затем в порядке очереди).
    /// - Parameter budgets: свои лимиты облаков — только файлы, которые помещаются в остаток.
    func claimNextUpload(providers: Set<CloudProviderKind>, budgets: [TransferBudget] = []) -> UploadTask? {
        lock.lock(); defer { lock.unlock() }
        let filter = Self.providerFilter(providers)
        let budgetFilters = budgets.map { Self.budgetFilter($0, remainingSQL: Self.uploadRemainingSQL, doneSQL: "uploaded_bytes") }
        let budgetSQL = budgetFilters.map { " AND \($0.sql)" }.joined()
        guard var task = (try? query("""
            SELECT \(Self.uploadColumns) FROM upload_tasks WHERE status = 'queued' AND \(filter.sql)\(budgetSQL)
            ORDER BY priority DESC, rowid LIMIT 1
            """, filter.values + budgetFilters.flatMap(\.values), map: Self.upload))?.first else { return nil }
        let changed = (try? run("UPDATE upload_tasks SET status = 'uploading', priority = 0, updated_at = ? WHERE id = ? AND status = 'queued'",
                                [.int(Self.now), .text(task.id)])) ?? 0
        guard changed == 1 else { return nil }
        task.status = .uploading
        return task
    }

    func uploadTask(id: String) -> UploadTask? {
        (try? query("SELECT \(Self.uploadColumns) FROM upload_tasks WHERE id = ?", [.text(id)], map: Self.upload))?.first
    }

    func uploads(status: UploadStatus, newestFirst: Bool, limit: Int) -> [UploadTask] {
        let order = newestFirst ? "updated_at DESC" : "priority DESC, rowid ASC"
        return (try? query("SELECT \(Self.uploadColumns) FROM upload_tasks WHERE status = ? ORDER BY \(order) LIMIT ?",
                           [.text(status.rawValue), .int(Int64(limit))], reader: true, map: Self.upload)) ?? []
    }

    func uploads(statuses: [UploadStatus], provider: CloudProviderKind? = nil) -> [UploadTask] {
        let placeholders = statuses.map { _ in "?" }.joined(separator: ",")
        let providerSQL = provider == nil ? "" : "AND provider = ?"
        return (try? query("SELECT \(Self.uploadColumns) FROM upload_tasks WHERE status IN (\(placeholders)) \(providerSQL) ORDER BY rowid",
                           statuses.map { .text($0.rawValue) } + (provider.map { [.text($0.rawValue)] } ?? []),
                           map: Self.upload)) ?? []
    }

    func updateUploadStatus(id: String, status: UploadStatus, error: String? = nil, kind: UploadErrorKind? = nil) {
        _ = try? run("UPDATE upload_tasks SET status = ?, last_error = ?, error_kind = ?, updated_at = ? WHERE id = ?",
                     [.text(status.rawValue), .text(error), .text(kind?.rawValue), .int(Self.now), .text(id)])
    }

    /// Новая сессия загрузки: отправка начинается с нуля.
    func saveUploadSession(id: String, uri: String, createdAt: Int64) {
        _ = try? run("UPDATE upload_tasks SET session_uri = ?, session_created_at = ?, uploaded_bytes = 0, updated_at = ? WHERE id = ?",
                     [.text(uri), .int(createdAt), .int(Self.now), .text(id)])
    }

    func resetUploadSession(id: String) {
        _ = try? run("UPDATE upload_tasks SET session_uri = NULL, session_created_at = NULL, uploaded_bytes = 0, updated_at = ? WHERE id = ?",
                     [.int(Self.now), .text(id)])
    }

    /// Сколько байт подтвердил сервер — сохраняется после каждой части.
    func setUploadedBytes(id: String, bytes: Int64) {
        _ = try? run("UPDATE upload_tasks SET uploaded_bytes = ?, updated_at = ? WHERE id = ?",
                     [.int(bytes), .int(Self.now), .text(id)])
    }

    func recordUploadRetry(id: String, retryCount: Int, error: String) {
        _ = try? run("UPDATE upload_tasks SET retry_count = ?, last_error = ?, updated_at = ? WHERE id = ?",
                     [.int(Int64(retryCount)), .text(error), .int(Self.now), .text(id)])
    }

    /// Сервер принял файл целиком; дальше — сверка хеша.
    /// `fileName` — имя, под которым облако сохранило файл (nil — без изменений).
    func markUploadTransferred(id: String, driveFileId: String, checksum: String?, size: Int64, fileName: String? = nil) {
        _ = try? run("""
            UPDATE upload_tasks SET status = 'verifying', drive_file_id = ?, md5_checksum = ?, uploaded_bytes = ?,
                file_name = COALESCE(?, file_name), session_uri = NULL, last_error = NULL, updated_at = ? WHERE id = ?
            """, [.text(driveFileId), .text(checksum), .int(size), .text(fileName), .int(Self.now), .text(id)])
    }

    func markUploadCompleted(id: String) {
        _ = try? run("UPDATE upload_tasks SET status = 'completed', last_error = NULL, error_kind = NULL, updated_at = ? WHERE id = ?",
                     [.int(Self.now), .text(id)])
    }

    @discardableResult
    func moveUploadStatuses(_ from: [UploadStatus], to: UploadStatus, provider: CloudProviderKind? = nil) -> Int {
        guard !from.isEmpty else { return 0 }
        let placeholders = from.map { _ in "?" }.joined(separator: ",")
        var values: [Value] = [.text(to.rawValue), .int(Self.now)] + from.map { .text($0.rawValue) }
        var sql = "UPDATE upload_tasks SET status = ?, updated_at = ? WHERE status IN (\(placeholders))"
        if let provider {
            sql += " AND provider = ?"
            values.append(.text(provider.rawValue))
        }
        return (try? run(sql, values)) ?? 0
    }

    /// «Возобновить» / «Повторить»: в начало очереди. Докачка продолжится с подтверждённого сервером байта.
    func resumeUpload(id: String) {
        _ = try? run("""
            UPDATE upload_tasks SET status = 'queued', priority = 1, retry_count = 0, last_error = NULL, updated_at = ?
            WHERE id = ? AND status NOT IN ('uploading', 'verifying', 'completed') AND error_kind IS NULL
            """, [.int(Self.now), .text(id)])
    }

    /// «Начать заново» / «Загрузить заново»: новая сессия, отправка с нуля, текущие размер и дата файла.
    func restartUpload(id: String, size: Int64, modifiedAt: Int64) {
        _ = try? run("""
            UPDATE upload_tasks SET status = 'queued', priority = 1, retry_count = 0, last_error = NULL, error_kind = NULL,
                session_uri = NULL, session_created_at = NULL, uploaded_bytes = 0, drive_file_id = NULL, md5_checksum = NULL,
                file_size = ?, local_modified_at = ?, updated_at = ?
            WHERE id = ? AND status NOT IN ('uploading', 'verifying')
            """, [.int(size), .int(modifiedAt), .int(Self.now), .text(id)])
    }

    func resumeAllPausedUploads() {
        _ = try? run("UPDATE upload_tasks SET status = 'queued', priority = 1, updated_at = ? WHERE status = 'paused'", [.int(Self.now)])
    }

    /// Повтор ошибок, которые не требуют начинать заново (их перезапускает отдельная кнопка).
    func retryFailedUploads() {
        _ = try? run("""
            UPDATE upload_tasks SET status = 'queued', retry_count = 0, last_error = NULL, updated_at = ?
            WHERE status = 'failed' AND error_kind IS NULL
            """, [.int(Self.now)])
    }

    func deleteUploads(statuses: [UploadStatus]) {
        let placeholders = statuses.map { _ in "?" }.joined(separator: ",")
        _ = try? run("DELETE FROM upload_tasks WHERE status IN (\(placeholders))", statuses.map { .text($0.rawValue) })
    }

    func uploadTotals() -> UploadTotals {
        var totals = UploadTotals()
        let rows = (try? query("""
            SELECT status, COUNT(*), SUM(file_size), SUM(MIN(uploaded_bytes, file_size)) FROM upload_tasks GROUP BY status
            """, reader: true) { s in
            (Self.text(s, 0) ?? "", Int(sqlite3_column_int64(s, 1)), sqlite3_column_int64(s, 2), sqlite3_column_int64(s, 3))
        }) ?? []
        for (raw, count, size, uploaded) in rows {
            guard let status = UploadStatus(rawValue: raw) else { continue }
            totals.countsByStatus[status] = count
            guard status != .cancelled else { continue }
            if UploadStatus.pending.contains(status) { totals.pendingCount += count }
            totals.totalBytes += size
            totals.uploadedBytes += status == .completed ? size : uploaded
        }
        totals.byProvider = uploadProgressByProvider()
        return totals
    }

    // MARK: Внешние диски с исходными файлами

    private static func localPathFilter(_ root: String) -> (sql: String, values: [Value]) {
        let escaped = root.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        return ("(local_path LIKE ? ESCAPE '\\')", [.text(escaped + "/%")])
    }

    func markUploadsWaitingForVolume(volumeRoot: String, message: String) {
        let filter = Self.localPathFilter(volumeRoot)
        _ = try? run("UPDATE upload_tasks SET status = 'waiting_for_volume', last_error = ?, updated_at = ? WHERE status = 'queued' AND \(filter.sql)",
                     [.text(message), .int(Self.now)] + filter.values)
    }

    func uploadVolumesAwaitingMount() -> Set<String> {
        let paths = (try? query("SELECT DISTINCT local_path FROM upload_tasks WHERE status = 'waiting_for_volume'") { s in
            Self.text(s, 0) ?? ""
        }) ?? []
        return Set(paths.compactMap { PathResolver.volumeRoot(for: $0) })
    }

    func requeueUploadsWaitingForVolume(volumeRoot: String) {
        let filter = Self.localPathFilter(volumeRoot)
        _ = try? run("UPDATE upload_tasks SET status = 'queued', last_error = NULL, updated_at = ? WHERE status = 'waiting_for_volume' AND \(filter.sql)",
                     [.int(Self.now)] + filter.values)
    }
}


// MARK: - Индикаторы передач в браузере облака

/// Общий прогресс передач внутри папки облака.
struct TransferAggregate: Sendable, Equatable {
    var total = 0
    var running = 0
    var queued = 0
    var paused = 0
    var failed = 0
    var waiting = 0
    var bytes: Int64 = 0
    var doneBytes: Int64 = 0
    var firstError: String?
}

extension DatabaseManager {
    /// Вызывается внутри транзакции вставки задач.
    fileprivate func insertTransferFolders(kind: String, provider: CloudProviderKind, taskId: String, folderIds: [String]) throws {
        for folderId in Set(folderIds) where !folderId.isEmpty || provider == .dropbox {
            try run("INSERT OR IGNORE INTO transfer_folders (kind, provider, folder_id, task_id) VALUES (?, ?, ?, ?)",
                    [.text(kind), .text(provider.rawValue), .text(folderId), .text(taskId)])
        }
    }

    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }

    /// Незавершённые задачи скачивания для файлов `fileIds` (ID в облаке).
    func activeDownloads(provider: CloudProviderKind, fileIds: [String]) -> [DownloadTask] {
        guard !fileIds.isEmpty else { return [] }
        var result: [DownloadTask] = []
        for chunk in stride(from: 0, to: fileIds.count, by: 500).map({ Array(fileIds[$0..<min($0 + 500, fileIds.count)]) }) {
            result += (try? query("""
                SELECT \(Self.taskColumns) FROM download_tasks
                WHERE provider = ? AND drive_file_id IN (\(Self.placeholders(chunk.count)))
                    AND status NOT IN ('completed', 'cancelled')
                """, [.text(provider.rawValue)] + chunk.map { .text($0) }, reader: true, map: Self.task)) ?? []
        }
        return result
    }

    /// Отправки в папку `parentId`: незавершённые и завершённые за последние `recentSeconds` секунд
    /// (строка-заглушка держится, пока обновлённый список папки не покажет настоящий файл).
    func uploadsInFolder(provider: CloudProviderKind, parentId: String, recentSeconds: Int64 = 120) -> [UploadTask] {
        (try? query("""
            SELECT \(Self.uploadColumns) FROM upload_tasks
            WHERE provider = ? AND parent_drive_id = ?
                AND (status NOT IN ('completed', 'cancelled') OR (status = 'completed' AND updated_at >= ?))
            ORDER BY rowid
            """, [.text(provider.rawValue), .text(parentId), .int(Self.now - recentSeconds)], reader: true,
            map: Self.upload)) ?? []
    }

    /// Общий прогресс незавершённых передач внутри папок `folderIds` (kind 'd' или 'u').
    func transferAggregates(kind: String, provider: CloudProviderKind, folderIds: [String]) -> [String: TransferAggregate] {
        guard !folderIds.isEmpty else { return [:] }
        let isDownload = kind == "d"
        let table = isDownload ? "download_tasks" : "upload_tasks"
        let size = isDownload ? "t.expected_size" : "t.file_size"
        let done = isDownload ? "MIN(t.downloaded_size, t.expected_size)" : "MIN(t.uploaded_bytes, t.file_size)"
        let runningStatuses = isDownload ? "'downloading', 'verifying'" : "'uploading', 'verifying'"
        let pausedStatuses = isDownload ? "'paused', 'paused_all'" : "'paused'"
        var result: [String: TransferAggregate] = [:]
        for chunk in stride(from: 0, to: folderIds.count, by: 500).map({ Array(folderIds[$0..<min($0 + 500, folderIds.count)]) }) {
            let rows = (try? query("""
                SELECT f.folder_id, COUNT(*), SUM(t.status IN (\(runningStatuses))), SUM(t.status = 'queued'),
                    SUM(t.status IN (\(pausedStatuses))), SUM(t.status = 'failed'), SUM(t.status LIKE 'waiting%'),
                    SUM(\(size)), SUM(\(done)), MAX(CASE WHEN t.status = 'failed' THEN t.last_error END)
                FROM transfer_folders f JOIN \(table) t ON t.provider = f.provider AND t.id = f.task_id
                WHERE f.kind = ? AND f.provider = ? AND f.folder_id IN (\(Self.placeholders(chunk.count)))
                    AND t.status NOT IN ('completed', 'cancelled')
                GROUP BY f.folder_id
                """, [.text(kind), .text(provider.rawValue)] + chunk.map { .text($0) }, reader: true) { s in
                (Self.text(s, 0) ?? "", TransferAggregate(
                    total: Int(sqlite3_column_int64(s, 1)), running: Int(sqlite3_column_int64(s, 2)),
                    queued: Int(sqlite3_column_int64(s, 3)), paused: Int(sqlite3_column_int64(s, 4)),
                    failed: Int(sqlite3_column_int64(s, 5)), waiting: Int(sqlite3_column_int64(s, 6)),
                    bytes: sqlite3_column_int64(s, 7), doneBytes: sqlite3_column_int64(s, 8),
                    firstError: Self.text(s, 9)))
            }) ?? []
            for (id, aggregate) in rows { result[id] = aggregate }
        }
        return result
    }

    /// ID незавершённых задач внутри папки (пауза / продолжение / отмена из контекстного меню папки).
    func transferTaskIds(kind: String, provider: CloudProviderKind, folderId: String) -> [String] {
        let table = kind == "d" ? "download_tasks" : "upload_tasks"
        return (try? query("""
            SELECT t.id FROM transfer_folders f JOIN \(table) t ON t.provider = f.provider AND t.id = f.task_id
            WHERE f.kind = ? AND f.provider = ? AND f.folder_id = ? AND t.status NOT IN ('completed', 'cancelled')
            """, [.text(kind), .text(provider.rawValue), .text(folderId)], reader: true) { s in Self.text(s, 0) ?? "" }) ?? []
    }
}

// MARK: - Folder sizes

/// Посчитанный размер папки облака.
struct FolderSize: Sendable, Equatable {
    var tally: FolderSizeTally
    var computedAt: Date
}

extension DatabaseManager {
    func allFolderSizes() -> [(RouteKey, FolderSize)] {
        (try? query("""
            SELECT provider, item_id, total_size, file_count, folder_count, native_doc_count, computed_at FROM folder_sizes
            """, reader: true) { s -> (RouteKey, FolderSize)? in
            guard let provider = Self.text(s, 0).flatMap(CloudProviderKind.init(rawValue:)) else { return nil }
            let tally = FolderSizeTally(totalSize: sqlite3_column_int64(s, 2), fileCount: Int(sqlite3_column_int64(s, 3)),
                                        folderCount: Int(sqlite3_column_int64(s, 4)),
                                        nativeDocCount: Int(sqlite3_column_int64(s, 5)))
            return (RouteKey(provider: provider, id: Self.text(s, 1) ?? ""),
                    FolderSize(tally: tally, computedAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(s, 6)))))
        })?.compactMap { $0 } ?? []
    }

    func saveFolderSize(_ size: FolderSize, for key: RouteKey) throws {
        try run("""
            INSERT OR REPLACE INTO folder_sizes
                (provider, item_id, total_size, file_count, folder_count, native_doc_count, computed_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """, [.text(key.provider.rawValue), .text(key.id), .int(size.tally.totalSize), .int(Int64(size.tally.fileCount)),
                  .int(Int64(size.tally.folderCount)), .int(Int64(size.tally.nativeDocCount)),
                  .int(Int64(size.computedAt.timeIntervalSince1970))])
    }
}

// MARK: - Transfer limits

extension DatabaseManager {
    func addTraffic(provider: CloudProviderKind, direction: TransferDirection, buckets: [Int64: Int64]) {
        lock.lock(); defer { lock.unlock() }
        guard (try? execute("BEGIN IMMEDIATE TRANSACTION;")) != nil else { return }
        for (minute, bytes) in buckets where bytes > 0 {
            _ = try? run("""
                INSERT INTO transfer_traffic (provider, direction, minute, bytes) VALUES (?, ?, ?, ?)
                ON CONFLICT (provider, direction, minute) DO UPDATE SET bytes = bytes + excluded.bytes
                """, [.text(provider.rawValue), .text(direction.rawValue), .int(minute), .int(bytes)])
        }
        if (try? execute("COMMIT;")) == nil { _ = try? execute("ROLLBACK;") }
    }

    func trafficBuckets(provider: CloudProviderKind, direction: TransferDirection, sinceMinute: Int64) -> [Int64: Int64] {
        let rows = (try? query("""
            SELECT minute, bytes FROM transfer_traffic WHERE provider = ? AND direction = ? AND minute >= ?
            """, [.text(provider.rawValue), .text(direction.rawValue), .int(sinceMinute)]) { s in
            (sqlite3_column_int64(s, 0), sqlite3_column_int64(s, 1))
        }) ?? []
        return Dictionary(rows, uniquingKeysWith: +)
    }

    func pruneTraffic(beforeMinute: Int64) {
        _ = try? run("DELETE FROM transfer_traffic WHERE minute < ?", [.int(beforeMinute)])
    }

    /// Условие «задачу облака можно запустить в остаток бюджета»: остаток файла помещается в бюджет,
    /// либо (если в остатке есть хотя бы порция) файл больше всего дневного лимита — качается частями
    /// по дням — или уже начат: начатый файл продолжается с того же байта и не ждёт, пока освободится
    /// бюджет на весь остаток (иначе его бы постоянно опережали мелкие файлы). Другие облака не ограничены.
    private static func budgetFilter(_ budget: TransferBudget?, remainingSQL: String, doneSQL: String) -> (sql: String, values: [Value]) {
        guard let budget else { return ("1", []) }
        var sql = "(provider <> ? OR MAX(\(remainingSQL), 0) <= ?"
        var values: [Value] = [.text(budget.provider.rawValue), .int(budget.remaining)]
        if budget.allowsOversized {
            sql += " OR \(remainingSQL) > ? OR \(doneSQL) > 0"
            values.append(.int(budget.limit))
        }
        return (sql + ")", values)
    }

    private static func downloadBudgetFilter(_ budget: TransferBudget?) -> (sql: String, values: [Value]) {
        budgetFilter(budget, remainingSQL: downloadRemainingSQL, doneSQL: "downloaded_size")
    }

    static let downloadRemainingSQL = "expected_size - downloaded_size"
    static let uploadRemainingSQL = "file_size - uploaded_bytes"

    /// Есть ли у облака скачивания, ждущие своей очереди.
    func hasQueuedDownloads(provider: CloudProviderKind) -> Bool {
        !((try? query("SELECT 1 FROM download_tasks WHERE status = 'queued' AND provider = ? LIMIT 1",
                      [.text(provider.rawValue)]) { _ in true }) ?? []).isEmpty
    }

    private func limitWaitingStats(table: String, remainingSQL: String, doneSQL: String, provider: CloudProviderKind,
                                   limit: Int64?) -> LimitWaitingStats {
        let limit = limit ?? Int64.max
        return (try? query("""
            SELECT COUNT(*), MIN(CASE WHEN rem <= ? THEN rem END), COALESCE(MAX(rem > ? OR done > 0), 0)
            FROM (SELECT MAX(\(remainingSQL), 0) AS rem, \(doneSQL) AS done FROM \(table)
                  WHERE status = 'waiting_daily_limit' AND provider = ?)
            """, [.int(limit), .int(limit), .text(provider.rawValue)], reader: true) { s in
            LimitWaitingStats(count: Int(sqlite3_column_int64(s, 0)), smallestFitting: Self.optionalInt(s, 1),
                              hasOversized: sqlite3_column_int64(s, 2) != 0)
        })?.first ?? LimitWaitingStats()
    }

    /// Скачивания облака, ждущие лимита.
    func downloadLimitStats(provider: CloudProviderKind, limit: Int64?) -> LimitWaitingStats {
        limitWaitingStats(table: "download_tasks", remainingSQL: Self.downloadRemainingSQL, doneSQL: "downloaded_size",
                          provider: provider, limit: limit)
    }

    /// Отправки облака, ждущие лимита.
    func uploadLimitStats(provider: CloudProviderKind, limit: Int64?) -> LimitWaitingStats {
        limitWaitingStats(table: "upload_tasks", remainingSQL: Self.uploadRemainingSQL, doneSQL: "uploaded_bytes",
                          provider: provider, limit: limit)
    }

    /// Очередь скачивания облака → ожидание лимита (`nextAttemptAt` — оценка, когда продолжим).
    @discardableResult
    func moveQueuedToDailyLimit(provider: CloudProviderKind, nextAttemptAt: Int64?, error: String) -> Int {
        (try? run("""
            UPDATE download_tasks SET status = 'waiting_daily_limit', next_attempt_at = ?, last_error = ?, updated_at = ?
            WHERE status = 'queued' AND provider = ?
            """, [nextAttemptAt.map { .int($0) } ?? .text(nil), .text(error), .int(Self.now), .text(provider.rawValue)])) ?? 0
    }

    func markLimitWaiting(id: String, nextAttemptAt: Int64?, error: String) {
        _ = try? run("""
            UPDATE download_tasks SET status = 'waiting_daily_limit', next_attempt_at = ?, last_error = ?, updated_at = ?
            WHERE id = ?
            """, [nextAttemptAt.map { .int($0) } ?? .text(nil), .text(error), .int(Self.now), .text(id)])
    }

    /// Ждущие лимита скачивания облака → снова в очередь (в прежнем порядке).
    @discardableResult
    func requeueLimitWaiting(provider: CloudProviderKind) -> Int {
        (try? run("""
            UPDATE download_tasks SET status = 'queued', last_error = NULL, next_attempt_at = NULL, updated_at = ?
            WHERE status = 'waiting_daily_limit' AND provider = ?
            """, [.int(Self.now), .text(provider.rawValue)])) ?? 0
    }

    /// Пробная задача после ответа облака о лимите: та, что дольше всех не пробовалась —
    /// если облако ограничило конкретный файл, следующая проба возьмёт другой.
    func claimDownloadProbe(provider: CloudProviderKind) -> DownloadTask? {
        lock.lock(); defer { lock.unlock() }
        guard let task = (try? query("""
            SELECT \(Self.taskColumns) FROM download_tasks WHERE status = 'waiting_daily_limit' AND provider = ?
            ORDER BY updated_at, rowid LIMIT 1
            """, [.text(provider.rawValue)], map: Self.task))?.first else { return nil }
        let changed = (try? run("""
            UPDATE download_tasks SET status = 'downloading', last_error = NULL, updated_at = ?
            WHERE id = ? AND status = 'waiting_daily_limit'
            """, [.int(Self.now), .text(task.id)])) ?? 0
        guard changed == 1 else { return nil }
        var claimed = task
        claimed.status = .downloading
        return claimed
    }

    /// Отправки облака (в очереди) → ожидание лимита.
    func moveQueuedUploadsToDailyLimit(provider: CloudProviderKind, error: String) {
        _ = try? run("""
            UPDATE upload_tasks SET status = 'waiting_daily_limit', last_error = ?, updated_at = ?
            WHERE status = 'queued' AND provider = ?
            """, [.text(error), .int(Self.now), .text(provider.rawValue)])
    }

    func claimUploadProbe(provider: CloudProviderKind) -> UploadTask? {
        lock.lock(); defer { lock.unlock() }
        guard var task = (try? query("""
            SELECT \(Self.uploadColumns) FROM upload_tasks WHERE status = 'waiting_daily_limit' AND provider = ?
            ORDER BY updated_at, rowid LIMIT 1
            """, [.text(provider.rawValue)], map: Self.upload))?.first else { return nil }
        let changed = (try? run("""
            UPDATE upload_tasks SET status = 'uploading', last_error = NULL, updated_at = ?
            WHERE id = ? AND status = 'waiting_daily_limit'
            """, [.int(Self.now), .text(task.id)])) ?? 0
        guard changed == 1 else { return nil }
        task.status = .uploading
        return task
    }
}

// MARK: - Status feed

extension DatabaseManager {
    /// Идущие и ждущие очереди скачивания по облакам: файлов, всего байт, получено байт.
    func downloadProgressByProvider() -> [CloudProviderKind: TransferProgress] {
        let rows = (try? query("""
            SELECT provider, COUNT(*), SUM(MAX(expected_size, 0)),
                SUM(MIN(downloaded_size, CASE WHEN expected_size > 0 THEN expected_size ELSE downloaded_size END))
            FROM download_tasks WHERE status IN ('queued', 'downloading', 'verifying') GROUP BY provider
            """, reader: true) { s in
            (Self.provider(s, 0), TransferProgress(files: Int(sqlite3_column_int64(s, 1)),
                                                   totalBytes: sqlite3_column_int64(s, 2), doneBytes: sqlite3_column_int64(s, 3)))
        }) ?? []
        return Dictionary(rows, uniquingKeysWith: { $1 })
    }

    func uploadProgressByProvider() -> [CloudProviderKind: TransferProgress] {
        let rows = (try? query("""
            SELECT provider, COUNT(*), SUM(file_size), SUM(MIN(uploaded_bytes, file_size))
            FROM upload_tasks WHERE status IN ('queued', 'uploading', 'verifying') GROUP BY provider
            """, reader: true) { s in
            (Self.provider(s, 0), TransferProgress(files: Int(sqlite3_column_int64(s, 1)),
                                                   totalBytes: sqlite3_column_int64(s, 2), doneBytes: sqlite3_column_int64(s, 3)))
        }) ?? []
        return Dictionary(rows, uniquingKeysWith: { $1 })
    }

    /// Какие из задач завершены (для сообщения «Готово: …»; ошибки и остановки по лимиту не считаются).
    func completedTaskIds(_ ids: [String], uploads: Bool) -> Set<String> {
        guard !ids.isEmpty else { return [] }
        let table = uploads ? "upload_tasks" : "download_tasks"
        let rows = (try? query("""
            SELECT id FROM \(table) WHERE status = 'completed' AND id IN (\(Self.placeholders(ids.count)))
            """, ids.map { .text($0) }, reader: true) { s in Self.text(s, 0) ?? "" }) ?? []
        return Set(rows)
    }

    /// Задачи статуса по томам (корень тома → число задач): ожидание диска, нехватка места.
    func downloadCountsByVolume(status: TaskStatus) -> [String: Int] {
        let rows = (try? query("""
            SELECT \(Self.volumeRootSQL), COUNT(*) FROM download_tasks WHERE status = ? GROUP BY 1
            """, [.text(status.rawValue)], reader: true) { s in
            (Self.text(s, 0) ?? "/", Int(sqlite3_column_int64(s, 1)))
        }) ?? []
        return Dictionary(rows, uniquingKeysWith: +)
    }
}
