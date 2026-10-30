import SwiftUI

// Legacy: kept only because this branch's ClipboardPlugin still names `ClipboardView`. The Clipboard plugin's own
// page replaces it; delete this file when that lands. History no longer shows copied text.
struct ClipboardView: View {
    var body: some View {
        FrogPage {
            FrogPageHeader(title: "Clipboard")
            FrogEmptyState(symbol: "clipboard", title: "Clipboard has its own page", message: "It comes with the Clipboard plugin.")
        }
    }
}
