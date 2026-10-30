import Foundation
import FrogCore

/// Another app on this Mac that asked Frog to dictate for it with a `frog://dictate` link. Frog records with
/// the person's own transcription rule, then sends the transcript to the app's reply link instead of copying
/// and pasting it.
///
///     frog://dictate?reply=<the app's URL>&caller=<its name>&rule=<rule name>&state=<token>
///     frog://dictate/stop?reply=…      frog://dictate/cancel?reply=…
///
/// The plain link starts a recording, or stops the one it started. The reply link gets `status=done` and
/// `text`, or `status=cancelled`, or `status=failed` and `error`, with `state` echoed back.
struct DictationHandoff: Equatable {
    enum Command: Equatable { case toggle, stop, cancel }
    enum Outcome: Equatable { case text(String), cancelled, failed(String) }

    let command: Command
    /// The name the popup shows: "Listening for Yappa…".
    let caller: String
    let reply: URL
    /// A rule chosen by name; nil uses the person's usual transcription rule.
    let rule: String?
    let state: String?

    /// Transcripts go only to apps: never to a web page, a file or back to Frog.
    static let refusedSchemes: Set<String> = ["http", "https", "file", "frog", "javascript", "data", "ftp", "mailto"]

    /// nil when the link is not a dictation link at all.
    static func parse(_ link: URL) throws -> DictationHandoff? {
        guard link.scheme?.lowercased() == "frog", link.host?.lowercased() == "dictate" else { return nil }
        let command: Command
        switch link.path.lowercased() {
        case "", "/": command = .toggle
        case "/stop": command = .stop
        case "/cancel": command = .cancel
        default: throw FrogError.message("Frog does not know this dictation link: \(link.path.prefix(40))")
        }
        let query = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String, limit: Int) -> String? {
            guard let text = query.first(where: { $0.name == name })?.value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            return String(text.prefix(limit))
        }
        guard let replyText = value("reply", limit: 2_000), let reply = URL(string: replyText),
              let scheme = reply.scheme?.lowercased(), !scheme.isEmpty else {
            throw FrogError.message("A dictation link needs the reply link of the app that asked.")
        }
        guard !refusedSchemes.contains(scheme) else {
            throw FrogError.message("Frog sends transcripts only to apps, not to \(scheme) links.")
        }
        let caller = value("caller", limit: 40) ?? scheme.prefix(1).uppercased() + scheme.dropFirst()
        return DictationHandoff(command: command, caller: caller, reply: reply,
                                rule: value("rule", limit: 120), state: value("state", limit: 200))
    }

    /// Whether `other` came from the same app, so its stop or cancel applies to this recording.
    func sameCaller(_ other: DictationHandoff) -> Bool {
        reply.scheme?.lowercased() == other.reply.scheme?.lowercased()
    }

    /// The reply link with the outcome added to whatever query it already had.
    func reply(_ outcome: Outcome) -> URL {
        var components = URLComponents(url: reply, resolvingAgainstBaseURL: false) ?? URLComponents()
        var items = components.queryItems ?? []
        switch outcome {
        case .text(let text): items += [URLQueryItem(name: "status", value: "done"), URLQueryItem(name: "text", value: text)]
        case .cancelled: items.append(URLQueryItem(name: "status", value: "cancelled"))
        case .failed(let message): items += [URLQueryItem(name: "status", value: "failed"), URLQueryItem(name: "error", value: message)]
        }
        if let state { items.append(URLQueryItem(name: "state", value: state)) }
        components.queryItems = items
        // `+` would read as a space on the other side.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url ?? reply
    }
}
