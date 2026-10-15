import AppKit
import SwiftUI
import FrogCore

/// A small picture of where a layout puts the window: a display outline with the target filled
/// in the accent colour. Layouts without a place of their own show a symbol.
struct WindowLayoutGlyph: View {
    let action: WindowAction

    static let size = CGSize(width: 22, height: 14)
    private static let display = CGRect(x: 0, y: 0, width: 16, height: 10)

    /// The symbol for a layout that has no target area, or that keeps the window's size.
    static func symbol(for action: WindowAction) -> String? {
        let name: String
        switch action {
        case .minimize: name = "arrow.down.right.and.arrow.up.left"
        case .restore: name = "arrow.uturn.backward"
        case .toggleFullScreen: name = "arrow.up.left.and.arrow.down.right"
        case .nextDisplay: name = "arrow.right.square"
        case .previousDisplay: name = "arrow.left.square"
        case .center: name = "plus.viewfinder"
        default: return nil
        }
        return NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil ? "macwindow" : name
    }

    /// The filled area, as a fraction of the display.
    static func area(for action: WindowAction) -> CGRect? {
        guard symbol(for: action) == nil,
              let target = WindowGeometry.target(action, window: CGRect(x: 4, y: 3, width: 8, height: 8), displays: [display]) else { return nil }
        return CGRect(x: target.minX / display.width, y: target.minY / display.height,
                      width: target.width / display.width, height: target.height / display.height)
    }

    var body: some View {
        Group {
            if let symbol = Self.symbol(for: action) {
                Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(FrogStyle.muted)
            } else {
                let area = Self.area(for: action)
                Canvas { context, size in
                    let bounds = CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)
                    if let area {
                        let fill = CGRect(x: bounds.minX + area.minX * bounds.width, y: bounds.minY + area.minY * bounds.height,
                                          width: area.width * bounds.width, height: area.height * bounds.height).insetBy(dx: 1.5, dy: 1.5)
                        context.fill(Path(roundedRect: fill, cornerRadius: 1.5), with: .color(FrogStyle.accent))
                    }
                    context.stroke(Path(roundedRect: bounds, cornerRadius: 3), with: .color(FrogStyle.muted), lineWidth: 1)
                }
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .accessibilityHidden(true)
    }
}
