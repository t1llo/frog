import SwiftUI
import FrogCore

/// A rule that only needs a shortcut: an application, a system action or a window layout.
/// Recording a shortcut switches the rule on, and clearing it switches the rule off.
struct ShortcutRuleRow<Leading: View>: View {
    let rule: Rule
    var detail: String?
    @ObservedObject var model: AppModel
    @ViewBuilder var leading: () -> Leading

    init(rule: Rule, detail: String? = nil, model: AppModel, @ViewBuilder leading: @escaping () -> Leading) {
        self.rule = rule; self.detail = detail; self.model = model; self.leading = leading
    }

    var body: some View {
        HStack(spacing: 10) {
            leading()
            VStack(alignment: .leading, spacing: 4) {
                Text(rule.name).font(FrogType.bodyMedium)
                if let detail {
                    Text(detail).font(FrogType.small).foregroundStyle(FrogStyle.muted).lineLimit(1)
                }
                if let issue = model.hotkeyErrors[rule.id] { Text(issue).font(FrogType.caption).foregroundStyle(FrogStyle.warning) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Toggle("Enable \(rule.name)", isOn: Binding(get: { rule.enabled }, set: { value in
                var updated = rule; updated.enabled = value
                do { try model.saveRule(updated) } catch { model.report(error) }
            })).labelsHidden().toggleStyle(.switch).controlSize(.mini)
            HotkeyRecorder(hotkey: Binding(get: { rule.hotkey }, set: { value in
                var updated = rule; updated.hotkey = value
                updated.enabled = value != nil
                do { try model.saveRule(updated) } catch { model.report(error) }
            }), showsClearButton: false)
        }
    }
}

/// The symbol a system action or window layout row shows, sized like an application icon.
struct ShortcutRuleSymbol: View {
    var symbol = "macwindow"
    var body: some View {
        Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(FrogStyle.muted).frame(width: 28, height: 28)
    }
}
