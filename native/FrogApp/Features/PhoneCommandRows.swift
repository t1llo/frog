import FrogCore

/// "Send clipboard to phone": the way to send files copied in Finder, which never go on their own,
/// and anything else on the clipboard. Listed only while Phone runs.
@MainActor final class PhoneCommandRows: CommandBarRowProviding {
    static let sendID = "phone:send-clipboard"

    func rows(in context: CommandBarContext) -> [CommandBarRow] {
        guard let phone = context.model.phone else { return [] }
        return [CommandBarRow(
            record: SearchRecord(id: Self.sendID, title: "Send clipboard to phone",
                                 subtitle: "Phone · \(phone.statusText)",
                                 keywords: "phone android companion send share files finder copy", symbol: "iphone"),
            primary: CommandRowAction(title: "Send") { @MainActor [weak model = context.model] in
                guard let phone = model?.phone else { return }
                let outcome = phone.sendClipboard()
                if !outcome.hasPrefix("Sent"), !outcome.hasPrefix("Sending") { throw FrogError.message(outcome) }
            })]
    }
}
