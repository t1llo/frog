// Token counts and rate limits from Codex CLI's session logs ($CODEX_HOME/sessions/**/rollout-*.jsonl,
// ~/.codex by default). Every line is {"timestamp", "type", "payload"}. The lines that matter:
//   session_meta        once per file, carries the thread id
//   turn_context        once per user turn, carries the model
//   token_usage_record  one per API response (Codex 0.153 and later)
//   event_msg/token_count  running totals plus the latest rate-limit snapshot
import Foundation

/// ChatGPT plan limits, fetched live or taken from the newest snapshot in Codex's logs. Codex
/// only logs them from response headers, so a logged one is as old as the last Codex request.
struct CodexLimits {
    let asOf: Date
    let usage: Usage
    let plan: String?
    let live: Bool
    let credits: CodexCredits?

    var hasData: Bool { !usage.limits.isEmpty || credits != nil }
}

actor CodexScanner {
    private let root: URL?
    init(root: URL? = nil) { self.root = root }
    /// Per-file parse state, kept between passes because files are read incrementally.
    private struct FileState {
        var offset: UInt64 = 0
        var path = ""
        var thread: String?
        // An explicit custom/local provider is not OpenAI account usage. Older logs omit it.
        var modelProvider: String?
        var isOpenAI: Bool { modelProvider == nil || modelProvider == "openai" }
        /// Set for forked threads; lines before it were copied from the parent.
        var forkedAt: Date?
        var model: String?
        var turnModels: [String: String] = [:]
        /// Last token_count total, to tell a new response from a repeated or rewritten total.
        var prevTotal = Tokens()
        /// Once a file has per-response records, its token_count lines are only used for limits.
        var sawRecord = false
        var runningKeys: Set<String> = []
    }

    /// OpenAI convention: `input` includes cached and cache-write tokens, `output` includes
    /// reasoning (`reasoning` is the part of it spent thinking, which grows with the effort).
    private struct Tokens: Equatable {
        var input = 0, cached = 0, cacheWrite = 0, output = 0, reasoning = 0, total = 0
        init() {}
        init(_ d: [String: Any]?) {
            input = Self.count(d?["input_tokens"])
            cached = min(input, Self.count(d?["cached_input_tokens"]))
            cacheWrite = min(input - cached, Self.count(d?["cache_write_input_tokens"]))
            output = Self.count(d?["output_tokens"])
            reasoning = Self.count(d?["reasoning_output_tokens"])
            total = Self.count(d?["total_tokens"])
        }
        private static func count(_ value: Any?) -> Int {
            guard let number = usageNumber(value), number >= 0,
                  let count = Int(exactly: number), count <= Int.max / 8 else { return 0 }
            return count
        }
        static func + (a: Tokens, b: Tokens) -> Tokens {
            var r = Tokens()
            r.input = a.input + b.input; r.cached = a.cached + b.cached; r.cacheWrite = a.cacheWrite + b.cacheWrite
            r.output = a.output + b.output; r.reasoning = a.reasoning + b.reasoning; r.total = a.total + b.total
            return r
        }
    }

    private var files: [String: FileState] = [:]
    /// Keyed by response id, or by timestamp and totals for older logs. Forks copy lines into the
    /// child's file, so the same key can appear in several files.
    private var records: [String: TokenRecord] = [:]
    private var limits: [String: (date: Date, json: [String: Any])] = [:]
    private var creditBalance: CodexCredits?
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static var home: URL {
        if let h = ProcessInfo.processInfo.environment["CODEX_HOME"], !h.isEmpty { return URL(fileURLWithPath: h) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    /// Records inside the horizon, the latest snapshot, and whether Codex has any logs at all.
    func scan() -> (records: [TokenRecord], limits: CodexLimits?, found: Bool) {
        let cutoff = Date().addingTimeInterval(-TokenScanner.horizon)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        var found = false
        for dir in ["sessions", "archived_sessions"] {
            // Compressed (.jsonl.zst) logs are skipped: Codex only compresses logs untouched for a
            // week, and only with an experimental feature turned on.
            guard let e = FileManager.default.enumerator(at: (root ?? Self.home).appendingPathComponent(dir),
                                                         includingPropertiesForKeys: keys) else { continue }
            for case let url as URL in e where url.pathExtension == "jsonl" {
                if Task.isCancelled { return ([], nil, false) }
                found = true
                guard let v = try? url.resourceValues(forKeys: Set(keys)),
                      let mtime = v.contentModificationDate, mtime >= cutoff,
                      let size = v.fileSize.map(UInt64.init) else { continue }
                var st = files[url.path] ?? FileState()
                if size < st.offset { st = FileState() }  // rewritten
                st.path = url.path
                if size > st.offset { st.offset += read(url, state: &st) }
                files[url.path] = st
            }
        }
        records = records.filter { $0.value.date >= cutoff }
        let main = limits["codex"].flatMap { parseCodexLogLimits($0.json, asOf: $0.date, lastCredits: creditBalance) }
        var usage = main?.usage ?? Usage()
        for id in limits.keys.sorted() where id != "codex" {
            let snapshot = limits[id]!
            let name = snapshot.json["limit_name"] as? String ?? id.replacingOccurrences(of: "_", with: " ")
            usage.limits += codexWindows(snapshot.json, prefix: "codex_\(id)", label: name,
                                         logged: true, now: snapshot.date)
        }
        let asOf = limits.values.map(\.date).max() ?? creditBalance?.asOf ?? .distantPast
        let combined = CodexLimits(asOf: asOf, usage: usage, plan: main?.plan, live: false, credits: creditBalance)
        return (Array(records.values), combined.hasData ? combined : nil, found)
    }

    private func read(_ url: URL, state st: inout FileState) -> UInt64 {
        guard let h = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? h.close() }
        guard (try? h.seek(toOffset: st.offset)) != nil, let data = try? h.readToEnd(),
              let end = data.lastIndex(of: 0x0A) else { return 0 }
        let needles = ["\"token_usage_record\"", "\"token_count\"", "\"turn_context\"", "\"session_meta\""]
            .map { Data($0.utf8) }
        var lineStart = data.startIndex
        while lineStart <= end {
            if Task.isCancelled { return UInt64(lineStart - data.startIndex) }
            let lineEnd = data[lineStart...end].firstIndex(of: 0x0A)!
            let line = data[lineStart..<lineEnd]
            lineStart = lineEnd + 1
            // Skip prompts/tool output before JSON parsing, without assuming JSON key order.
            guard needles.contains(where: { line.range(of: $0) != nil }) else { continue }
            add(line, &st)
        }
        return UInt64(end - data.startIndex + 1)
    }

    private func add(_ line: Data, _ st: inout FileState) {
        guard let d = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = d["type"] as? String, let p = d["payload"] as? [String: Any],
              let ts = d["timestamp"] as? String, let date = iso.date(from: ts) ?? isoDate(ts) else { return }
        switch type {
        case "session_meta":
            guard st.thread == nil else { return }
            st.thread = p["id"] as? String
            st.modelProvider = p["model_provider"] as? String
            if p["forked_from_id"] != nil { st.forkedAt = date }
        case "turn_context":
            if let provider = p["model_provider"] as? String { st.modelProvider = provider }
            guard let model = p["model"] as? String else { return }
            st.model = model
            if let turn = p["turn_id"] as? String { st.turnModels[turn] = model }
        case "token_usage_record":
            // A fork's copy of its parent's records belongs to the parent thread.
            // Current logs use session_id; earlier logs use thread_id, and some omit both.
            guard st.isOpenAI, let usage = p["usage"] as? [String: Any],
                  date >= st.forkedAt ?? .distantPast else { return }
            let owners = [p["thread_id"] as? String, p["session_id"] as? String].compactMap { $0 }.filter { !$0.isEmpty }
            guard Set(owners).count <= 1, st.thread == nil || owners.allSatisfy({ $0 == st.thread }) else { return }
            if st.thread == nil { st.thread = owners.first }
            if !st.sawRecord {
                // New-format records supersede every running-total fallback from this file.
                for key in st.runningKeys { records.removeValue(forKey: key) }
                st.runningKeys = []
                st.sawRecord = true
            }
            let model = (p["turn_id"] as? String).flatMap { st.turnModels[$0] } ?? st.model
            let id = (p["response_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let key = id.map { "r|\($0)" } ?? "s|\(st.thread ?? st.path)|\(ts)|\(model ?? "unknown")"
            put(key, date: date, model: model, Tokens(usage))
        case "event_msg" where p["type"] as? String == "token_count":
            guard st.isOpenAI else { return }
            if let rl = p["rate_limits"] as? [String: Any] {
                let rawID = (rl["limit_id"] as? String ?? "").lowercased()
                let id = rawID.isEmpty ? "codex" : rawID
                if date >= (limits[id]?.date ?? .distantPast) { limits[id] = (date, rl) }
                // Only the main plan's bucket owns the account credit balance.
                if id == "codex" {
                    if date >= (creditBalance?.asOf ?? .distantPast),
                       let credits = parseCodexCredits(rl["credits"], asOf: date, live: false) {
                        creditBalance = credits
                    }
                }
            }
            guard let info = p["info"] as? [String: Any] else { return }
            let total = Tokens(info["total_token_usage"] as? [String: Any])
            let last = Tokens(info["last_token_usage"] as? [String: Any])
            defer { st.prevTotal = total }
            // Older logs only have running totals. Count `last` when it is exactly what moved the
            // total; that skips limit-only repeats, post-compaction estimates and resets.
            guard !st.sawRecord, total == st.prevTotal + last, last.total > 0,
                  date >= st.forkedAt ?? .distantPast else { return }
            let key = "t|\(st.thread ?? st.path)|\(ts)|\(total.total)|\(last.total)"
            st.runningKeys.insert(key)
            put(key, date: date, model: st.model, last)
        default:
            return
        }
    }

    private func put(_ key: String, date: Date, model: String?, _ u: Tokens) {
        let previous = records[key]
        let model = model ?? previous?.model ?? "unknown"
        let input = max(previous?.input ?? 0, u.input - u.cached - u.cacheWrite)
        // Reasoning bills as output at every effort. Codex copies the API's output_tokens, which
        // already includes it; only when the total says it was left out is it added back.
        let reportedOutput = u.reasoning > 0 && u.total == u.input + u.output + u.reasoning ? u.output + u.reasoning : u.output
        let output = max(previous?.output ?? 0, reportedOutput)
        let cacheWrite = max(previous?.cacheWrite ?? 0, u.cacheWrite)
        let cached = max(previous?.cacheRead ?? 0, u.cached)
        records[key] = TokenRecord(
            date: min(previous?.date ?? date, date), model: model, provider: .openai, source: .codex,
            input: input, output: output, cacheWrite: cacheWrite, cacheRead: cached,
            cost: openAICost(model: model, input: input, output: output, cacheWrite: cacheWrite, cacheRead: cached))
    }
}

func parseCodexLogLimits(_ json: [String: Any], asOf: Date, lastCredits: CodexCredits? = nil) -> CodexLimits? {
    var usage = Usage()
    usage.limits = codexWindows(json, prefix: "codex", logged: true, now: asOf)
    let limits = CodexLimits(asOf: asOf, usage: usage, plan: json["plan_type"] as? String, live: false,
                             credits: parseCodexCredits(json["credits"], asOf: asOf, live: false) ?? lastCredits)
    return limits.hasData ? limits : nil
}

/// Codex's windows are set by the server; name them by length the way Codex's own TUI does.
func windowLabel(_ minutes: Int?) -> String {
    switch minutes ?? 0 {
    case 0: return "Limit"
    case ..<360: return "Session"
    case 1380...1500: return "Day"
    case 10000...10200: return "Week"
    case 43000...45000: return "Month"
    case let m where m % 1440 == 0: return "\(m / 1440) days"
    case let m: return "\(m / 60) hours"
    }
}

extension CodexLimits {
    /// A passed reset says nothing about usage in the new window, including use elsewhere.
    /// Keep the original snapshot internally, but omit unknown windows from the readout.
    func current(now: Date) -> Usage {
        var u = usage
        u.limits = u.limits.filter { $0.resetsAt.map { $0 > now } ?? true }
        return u
    }
}
