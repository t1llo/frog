import Foundation
import CryptoKit

/// Pi session trees can branch, fork into copied files, or be rewritten. Reread the recent
/// horizon when a file changes and deduplicate identical assistant messages across forks; count all real calls,
/// including branches no longer on the active path. Never count compaction's tokensBefore.
actor PiScanner {
    private struct CachedFile {
        let modified: Date
        let size: Int
        let records: [String: TokenRecord]
    }
    private var filesByPath: [String: CachedFile] = [:]
    private let root: URL?
    init(root: URL? = nil) { self.root = root }

    func scan() -> [TokenRecord] {
        let now = Date()
        let cutoff = now.addingTimeInterval(-TokenScanner.horizon)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = FileManager.default.enumerator(at: root ?? piAgentDirectory.appendingPathComponent("sessions"),
                                                        includingPropertiesForKeys: keys) else { filesByPath.removeAll(); return [] }
        var records: [String: TokenRecord] = [:]
        var retained: [String: CachedFile] = [:]
        for case let url as URL in files where url.pathExtension == "jsonl" {
            if Task.isCancelled { return [] }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  let modified = values.contentModificationDate, modified >= cutoff,
                  let size = values.fileSize else { continue }
            if let cached = filesByPath[url.path], cached.modified == modified, cached.size == size {
                retained[url.path] = cached
                records.merge(cached.records.filter { $0.value.date >= cutoff && $0.value.date <= now }) { _, new in new }
                continue
            }
            guard let data = try? Data(contentsOf: url) else { continue }
            var parsed: [String: TokenRecord] = [:]
            let end = data.lastIndex(of: 0x0A) ?? data.startIndex
            // Ignore incomplete final lines, even if they happen to be parseable JSON.
            for line in data[..<end].split(separator: 0x0A) {
                if Task.isCancelled { return [] }
                guard let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      entry["type"] as? String == "message",
                      let message = entry["message"] as? [String: Any], message["role"] as? String == "assistant",
                      let usage = message["usage"] as? [String: Any],
                      let model = message["model"] as? String,
                      let providerID = message["provider"] as? String else { continue }
                let provider: Provider
                switch providerID {
                case "anthropic": provider = .claude
                case "openai", "openai-codex": provider = .openai
                default: continue // Bedrock, proxies and unrelated providers are not subscription accounts.
                }
                let date = usageNumber(message["timestamp"]).map { Date(timeIntervalSince1970: $0 / 1000) }
                    ?? isoDate(entry["timestamp"])
                guard let date, date >= cutoff,
                      let fingerprint = try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]) else { continue }
                func count(_ key: String) -> Int {
                    guard let n = usageNumber(usage[key]), n.isFinite, n >= 0, n < Double(Int.max) else { return 0 }
                    return Int(n)
                }
                // Pi normalizes input to uncached tokens, and output already includes reasoning.
                let input = count("input"), output = count("output")
                let write = count("cacheWrite"), read = count("cacheRead"), hour = min(write, count("cacheWrite1h"))
                guard input > 0 || output > 0 || write > 0 || read > 0 else { continue }
                let key = SHA256.hash(data: fingerprint).map { String(format: "%02x", $0) }.joined()
                parsed[key] = TokenRecord(date: date, model: model, provider: provider, source: .pi,
                    input: input, output: output, cacheWrite: write, cacheRead: read,
                    cost: apiCost(model: model, input: input, output: output, cacheWrite5m: write - hour,
                                  cacheWrite1h: hour, cacheRead: read, fast: false), cacheWrite1h: hour)
            }
            retained[url.path] = CachedFile(modified: modified, size: size, records: parsed)
            records.merge(parsed.filter { $0.value.date <= now }) { _, new in new }
        }
        filesByPath = retained
        return Array(records.values)
    }
}
