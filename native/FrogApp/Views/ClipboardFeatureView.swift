import SwiftUI
import FrogCore

struct ClipboardFeatureView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        HistoryView(initialFilter: .clipboard, clipboardOnly: true)
    }
}
