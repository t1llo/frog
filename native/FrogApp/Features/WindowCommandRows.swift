import AppKit
import FrogCore

/// The command bar's rows for window commands. Every window record beyond the layouts comes
/// from here.
final class WindowCommandRows: CommandBarRowProviding {
    static let targetChanged = "The target application changed. Open the command bar again."

    func rows(in context: CommandBarContext) -> [CommandBarRow] {
        let frontPID = context.frontPID
        return WindowSwitches(context.model.configuration.preferences).commandBarCommands.map { command in
            CommandBarRow(record: SearchRecord(id: "layout:command.\(command.rawValue)", title: command.title,
                                               subtitle: command.commandBarSubtitle, keywords: command.keywords, symbol: command.symbol),
                          primary: CommandRowAction(title: "Open") { [weak model = context.model] in
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == frontPID else {
                    throw FrogError.message(Self.targetChanged)
                }
                model?.windowLayout.handle(command, pressed: true)
            })
        }
    }
}
