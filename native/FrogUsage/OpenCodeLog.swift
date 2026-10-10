// Token counts from OpenCode, which keeps every session in one SQLite database
// (~/.local/share/opencode/opencode.db, WAL mode). Each assistant message row carries the
// provider, model and token counts of one model call. OpenCode logs the ChatGPT subscription
// login as provider "openai" with cost 0, so the API cost is recomputed here from list prices.
import Foundation
import SQLite3

actor OpenCodeReader {
    private let root: URL?
    private struct Stamp: Equatable {
        let inode: UInt64
        let size: UInt64
        let modified: Date
        let created: Date
    }
    private struct Snapshot {
        let stamps: [Stamp?]
        let rows: [(key: String, record: TokenRecord)]
    }
    private var snapshots: [String: Snapshot] = [:]
    init(root: URL? = nil) { self.root = root }
    static var dataDir: URL {
        openCodeDataDirectory
    }

    /// Release builds write opencode.db, dev builds opencode-<channel>.db.
    private var databases: [URL] {
        let directory = root ?? Self.dataDir
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasPrefix("opencode") && $0.hasSuffix(".db") }.map { directory.appendingPathComponent($0) }
    }

    /// Reread changed databases in full: mutable replies, reverts and fork copies make a plain
    /// row cursor unreliable. Unchanged DB/WAL pairs reuse counters, not conversation contents.
    func scan() -> (records: [TokenRecord], found: Bool, warning: String?) {
        let dbs = databases
        let since = Int64((Date().timeIntervalSince1970 - TokenScanner.horizon) * 1000)
        // Forking a session copies its messages under new ids with identical contents, so dedupe
        // on the contents rather than the id.
        var seen = Set<String>()
        var out: [TokenRecord] = []
        var unreadable = false
        snapshots = snapshots.filter { path, _ in dbs.contains { $0.path == path } }
        for url in dbs {
            let before = stamps(url)
            let previous = snapshots[url.path]
            let rows: [(key: String, record: TokenRecord)]
            if let previous, previous.stamps == before, before.first.flatMap({ $0 }) != nil {
                rows = previous.rows
            } else if let fresh = query(url, since: since) {
                rows = fresh
                // A concurrent writer must trigger another read rather than blessing stale data.
                if before == stamps(url) { snapshots[url.path] = Snapshot(stamps: before, rows: fresh) }
            } else {
                unreadable = true
                rows = previous?.rows ?? []
            }
            for r in rows where r.record.date.timeIntervalSince1970 * 1000 >= Double(since) && seen.insert(r.key).inserted {
                out.append(r.record)
            }
        }
        return (out, !dbs.isEmpty, unreadable ? "OpenCode database could not be refreshed. Any previous counters are retained until the next successful read." : nil)
    }

    private func stamps(_ url: URL) -> [Stamp?] {
        [url.path, url.path + "-wal"].map { path in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let inode = attributes[.systemFileNumber] as? UInt64,
                  let size = attributes[.size] as? UInt64,
                  let modified = attributes[.modificationDate] as? Date,
                  let created = attributes[.creationDate] as? Date else { return nil }
            return Stamp(inode: inode, size: size, modified: modified, created: created)
        }
    }

    /// Opened through SQLite itself, so writes still sitting in the -wal file are seen. A
    /// read-only connection cannot recreate the -wal and -shm files OpenCode removes when it
    /// quits, so if it cannot read, retry as a normal connection. Either way it only runs SELECTs.
    private func query(_ url: URL, since: Int64) -> [(key: String, record: TokenRecord)]? {
        query(url, since: since, flags: SQLITE_OPEN_READONLY)
            ?? query(url, since: since, flags: SQLITE_OPEN_READWRITE)
    }

    private func query(_ url: URL, since: Int64, flags: Int32) -> [(key: String, record: TokenRecord)]? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK else { sqlite3_close(db); return nil }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)
        // V2 uses session_message and model.{providerID,id}; migrated databases can
        // retain V1 message rows too. Project only counters, never message contents.
        var schema: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('message','session_message')", -1, &schema, nil) == SQLITE_OK else { return nil }
        var tables = Set<String>()
        while sqlite3_step(schema) == SQLITE_ROW {
            if let name = sqlite3_column_text(schema, 0) { tables.insert(String(cString: name)) }
        }
        sqlite3_finalize(schema)
        guard !tables.isEmpty else { return nil }
        let sql = ["message", "session_message"].filter { tables.contains($0) }.map { table in
            let modern = table == "session_message"
            let provider = modern ? "$.model.providerID" : "$.providerID"
            let model = modern ? "$.model.id" : "$.modelID"
            let assistant = modern ? "type = 'assistant'" : "json_extract(data,'$.role') = 'assistant'"
            return """
            SELECT json_extract(data,'\(provider)'), json_extract(data,'\(model)'),
                    coalesce(json_extract(data,'$.time.created'), time_created), json_extract(data,'$.time.completed'),
                   json_extract(data,'$.tokens.input'), json_extract(data,'$.tokens.output'),
                   json_extract(data,'$.tokens.reasoning'), json_extract(data,'$.tokens.cache.read'),
                   json_extract(data,'$.tokens.cache.write')
            FROM \(table)
            WHERE time_created >= ?1
              AND CASE WHEN json_valid(data) THEN \(assistant) ELSE 0 END
            """
        }.joined(separator: " UNION ALL ")
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, since)
        var rows: [(String, TokenRecord)] = []
        var result = sqlite3_step(stmt)
        while result == SQLITE_ROW {
            if Task.isCancelled { return nil }
            defer { result = sqlite3_step(stmt) }
            let text = { (i: Int32) in sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" }
            let int = { (i: Int32) in Int(sqlite3_column_int64(stmt, i)) }
            let providerID = text(0)
            let provider: Provider
            switch providerID {
            case "openai", "azure": provider = .openai
            case "anthropic": provider = .claude
            default: continue  // Copilot, OpenRouter, Zen and others bill differently
            }
            let model = normalize(text(1))
            let input = int(4), output = int(5) + int(6), read = int(7), write = int(8)
            guard input + output + read + write > 0 else { continue }  // not yet answered
            let date = Date(timeIntervalSince1970: Double(int(2)) / 1000)
            // OpenCode's input excludes both cache reads and writes, like Anthropic's. Its output
            // excludes reasoning, which bills as output, so the two are added back together.
            let cost = provider == .openai
                ? openAICost(model: model, input: input, output: output, cacheWrite: write, cacheRead: read)
                : apiCost(model: model, input: input, output: output, cacheWrite5m: write, cacheWrite1h: 0,
                          cacheRead: read, fast: false)
            let key = [providerID, model, text(2), text(3), "\(input)", "\(output)", "\(read)", "\(write)"].joined(separator: "|")
            rows.append((key, TokenRecord(date: date, model: model, provider: provider, source: .opencode,
                                          input: input, output: output, cacheWrite: write, cacheRead: read, cost: cost)))
        }
        return result == SQLITE_DONE ? rows : nil
    }

    /// "openai/gpt-5.2-medium" -> "gpt-5.2". Some auth plugins put the reasoning effort in the id.
    private func normalize(_ id: String) -> String {
        var m = id.split(separator: "/").last.map(String.init) ?? id
        for effort in ["-minimal", "-low", "-medium", "-high", "-xhigh"] where m.hasSuffix(effort) {
            m.removeLast(effort.count)
        }
        return m
    }
}
