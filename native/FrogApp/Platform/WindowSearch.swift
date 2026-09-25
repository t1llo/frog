import Foundation

enum WindowSearch {
    static func score(_ query: String, in text: String) -> Int? {
        let query = Array(query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).filter { !$0.isWhitespace })
        guard !query.isEmpty else { return 0 }
        let text = Array(text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current))
        var cursor = 0, previous = -2, score = 0
        for letter in query {
            guard let index = text.indices.dropFirst(cursor).first(where: { text[$0] == letter }) else { return nil }
            score += index == previous + 1 ? 8 : 1
            if index == 0 || text[index - 1].isWhitespace { score += 5 }
            score -= index - cursor
            cursor = index + 1; previous = index
        }
        return score
    }
    static func filter(_ windows: [SwitcherWindow], query: String) -> [SwitcherWindow] {
        guard !query.isEmpty else { return windows }
        return windows.enumerated().compactMap { index, window -> (Int, Int, SwitcherWindow)? in
            guard let score = score(query, in: window.appName + " " + window.title) else { return nil }
            return (score, index, window)
        }.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 > $1.0 }.map(\.2)
    }
}
