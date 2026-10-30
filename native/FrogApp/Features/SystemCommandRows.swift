import AppKit
import FrogCore

/// Mac commands such as Lock screen and the Finder folders. Settings panes are listed once, from the System
/// Settings catalogue. Contributed by the Shortcuts plugin, so they are listed while it is on.
@MainActor final class SystemCommandRows: CommandBarRowProviding {
    private let perform: @MainActor (SystemAction) -> Void
    init(perform: @escaping @MainActor (SystemAction) -> Void) { self.perform = perform }

    func rows(in context: CommandBarContext) -> [CommandBarRow] {
        let frontPID = context.frontPID, perform = perform
        return SystemAction.allCases.filter { SystemActionController.destination(for: $0)?.scheme != "x-apple.systempreferences" }.map { action in
            CommandBarRow(record: SearchRecord(id: "system:\(action.rawValue)", title: action.title, subtitle: action.scope, keywords: "frog command shortcut", symbol: action.symbol),
                          primary: CommandRowAction(title: "Run") {
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == frontPID else { throw FrogError.message(CommandBarContext.targetChanged) }
                perform(action)
            })
        }
    }
}
