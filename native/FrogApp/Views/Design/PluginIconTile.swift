import SwiftUI

/// A plugin's or feature's icon, as System Settings draws them: a white SF Symbol on a rounded square filled
/// with the tint. The same in light and dark, so a feature is recognised by its colour everywhere.
struct PluginIconTile: View {
    enum Size: CGFloat {
        /// Sidebar rows.
        case sidebar = 20
        /// List and table rows.
        case list = 28
        /// Page and card headers.
        case header = 40

        fileprivate var radius: CGFloat {
            switch self {
            case .sidebar: FrogStyle.smallRadius
            case .list: FrogStyle.controlRadius
            case .header: FrogStyle.cardRadius
            }
        }
    }

    let symbol: String
    let tint: Color
    var size: Size = .list

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size.radius, style: .continuous)
        Image(systemName: symbol)
            .font(.system(size: size.rawValue * 0.52, weight: .medium))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(.white)
            .frame(width: size.rawValue, height: size.rawValue)
            .background(tint.gradient, in: shape)
            // A hairline keeps pale tints apart from a white page.
            .overlay(shape.strokeBorder(.black.opacity(0.06), lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}
