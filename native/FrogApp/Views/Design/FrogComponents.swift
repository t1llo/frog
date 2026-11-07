import SwiftUI
import AppKit

// Small components shared across surfaces: the status item popups' header and footer, a page's state pill,
// commands in text, and badges.

/// The top of every status item popup: the feature's tile and name, then its actions on the trailing side.
/// Its content starts where the cards' text does.
struct FrogPopupHeader<Trailing: View>: View {
    let symbol: String
    let tint: PluginTint
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: FrogStyle.space8) {
            PluginIconTile(symbol: symbol, tint: tint.color, size: .sidebar)
            Text(L10n.text(title)).font(FrogType.section).lineLimit(1).fixedSize()
            Spacer(minLength: FrogStyle.space6)
            trailing
        }.padding(.horizontal, FrogStyle.cardPadding).frame(height: 40)
    }
}

/// The bottom of every status item popup: a `FrogFooter` with the popup's status on the leading side and Close
/// `esc` on the trailing side. `close` makes Close a button for the pointer and VoiceOver; Escape always works.
struct FrogPopupFooter<Status: View>: View {
    var close: (() -> Void)? = nil
    @ViewBuilder var status: Status

    init(close: (() -> Void)? = nil, @ViewBuilder status: () -> Status) { self.close = close; self.status = status() }

    var body: some View {
        FrogFooter { status } actions: { FrogFooterHint("Close", keys: "esc", action: close) }
    }
}

/// A state, never an action: a dot and a word or two in muted text, with no fill or outline, so it can never be
/// mistaken for the buttons beside it ("Connected", "Installed", "Allowed", "Running", "Until 14:00"). The dot says
/// the kind of state: `.good` green for granted or working, `.active` the accent for something under way, `.warning`
/// and `.critical` for trouble, `.off` a hollow ring for a state that is simply not on. Used in rows' trailing
/// slots, page headers, setup and popups alike; buttons are the only filled pills.
struct FrogStatusLabel: View {
    enum Tone { case good, active, warning, critical, off }
    let text: String
    var tone: Tone = .good

    init(_ text: String, tone: Tone = .good) { self.text = text; self.tone = tone }

    var body: some View {
        HStack(spacing: FrogStyle.space6) {
            Group {
                if tone == .off { Circle().strokeBorder(FrogStyle.muted, lineWidth: 1.5) } else { Circle().fill(color) }
            }.frame(width: 7, height: 7)
            Text(L10n.text(text)).font(FrogType.small).foregroundStyle(FrogStyle.muted).lineLimit(1)
        }
        // A control's height, so it lines up with switches and buttons in the rows around it.
        .frame(height: FrogStyle.compactHeight)
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch tone {
        case .good: FrogStyle.good
        case .active: FrogStyle.accent
        case .warning: FrogStyle.warning
        case .critical: FrogStyle.critical
        case .off: FrogStyle.muted
        }
    }
}

/// The former page state pill, now drawn as a `FrogStatusLabel`; new code uses `FrogStatusLabel` directly.
struct FrogStatePill: View {
    let text: String
    let on: Bool
    var body: some View { FrogStatusLabel(text, tone: on ? .good : .off) }
}

/// Text with `backticked` commands, the commands set in the mono font on a faint fill and the backticks dropped.
enum InlineCode {
    static func attributed(_ text: String) -> AttributedString {
        var result = AttributedString()
        for (index, part) in text.components(separatedBy: "`").enumerated() {
            var piece = AttributedString(part)
            if index % 2 == 1 {
                piece.font = FrogType.mono
                piece.backgroundColor = FrogStyle.hover
            }
            result += piece
        }
        return result
    }
}

/// A command to type, as a chip in the mono font; a click copies it.
struct FrogCodeChip: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            ViewActions.copy(text); copied = true
            Task { try? await Task.sleep(for: FrogMotion.confirmation); copied = false }
        } label: {
            HStack(spacing: FrogStyle.space6) {
                Text(text).font(FrogType.mono).foregroundStyle(FrogStyle.ink)
                Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
            }
            .padding(.horizontal, FrogStyle.space8).frame(height: FrogStyle.compactHeight)
            .background(FrogStyle.control, in: RoundedRectangle(cornerRadius: FrogStyle.smallRadius, style: .continuous))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).help("Copy \(text)").accessibilityLabel("Copy \(text)")
    }
}

// MARK: Add buttons

/// The one way a page or section offers to add something: a secondary pill with a plus, "Add rule", "Add app".
/// In a page header (28 tall) or a section header (24, like the rows' actions). When adding means choosing what
/// to add first, the pill takes a chevron (`FrogAddLabel(menu: true)`) and opens a searchable `FrogDropdownList`,
/// as Shortcuts' add buttons do.
struct FrogAddButton: View {
    let title: String
    let action: () -> Void
    init(_ title: String, action: @escaping () -> Void) { self.title = title; self.action = action }

    var body: some View {
        Button(action: action) { FrogAddLabel(title: title, menu: false) }
            .buttonStyle(.frog()).accessibilityLabel(L10n.text(title))
    }
}

/// The label of `FrogAddButton` and of an add button that opens a list of what to add: a plus, the title and,
/// for a list, a chevron.
struct FrogAddLabel: View {
    let title: String
    let menu: Bool
    var body: some View {
        HStack(spacing: FrogStyle.space4) {
            Image(systemName: "plus").font(.system(size: 10, weight: .bold)).accessibilityHidden(true)
            Text(L10n.text(title)).lineLimit(1)
            if menu {
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                    .padding(.leading, FrogStyle.space2).accessibilityHidden(true)
            }
        }
    }
}

// MARK: Sheet body

/// The scrolling body of a sheet, between its header and its `FrogSheetButtons`. The sheet grows with its content up
/// to `maxHeight` (and never taller than the screen leaves room for), so a sheet whose content fits shows all of it,
/// with nothing faded or cut under its buttons. Only content taller than that scrolls, and only then does its bottom
/// edge fade above the buttons, with that much empty margin after the last row, so scrolled to the end the last row
/// and footnote sit whole above the fade.
///
///     FrogSheetScroll { FrogSection("Then") { … } }
///     FrogSheetButtons { … } trailing: { … }
///
/// No sheet sets its own `frame(maxHeight:)`, `fixedSize` or `bottomScrollFade()` around its body.
struct FrogSheetScroll<Content: View>: View {
    /// The tallest the body grows before it scrolls.
    var maxHeight: CGFloat = FrogSheetScrollMetrics.maxHeight
    @ViewBuilder var content: Content
    @State private var contentHeight: CGFloat = 0

    init(maxHeight: CGFloat = FrogSheetScrollMetrics.maxHeight, @ViewBuilder content: () -> Content) {
        self.maxHeight = maxHeight; self.content = content()
    }

    var body: some View {
        let limit = min(maxHeight, FrogSheetScrollMetrics.screenLimit)
        let overflows = contentHeight > limit + 0.5
        ScrollView {
            content.frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollIndicators(overflows ? .automatic : .never)
        // Always the same modifier, so the content keeps its state when the sheet starts or stops scrolling.
        .bottomScrollFade(height: overflows ? FrogSheetScrollMetrics.fade : 0)
        .frame(maxHeight: limit).fixedSize(horizontal: false, vertical: true)
    }
}

enum FrogSheetScrollMetrics {
    /// Tall enough for every sheet Frog has to show its whole body in the default window.
    static let maxHeight: CGFloat = 560
    /// The fade above the buttons while the body scrolls: tall enough to read as a fade, not as a cut line.
    static let fade: CGFloat = FrogStyle.space16 * 2
    /// What the screen leaves for a sheet's body once its header, buttons and the menu bar are taken off.
    @MainActor static var screenLimit: CGFloat {
        guard let screen = NSScreen.main else { return maxHeight }
        return max(240, screen.visibleFrame.height - 260)
    }
}

// MARK: Sheet buttons

/// The row of buttons at the bottom of every sheet: what removes something (Delete) alone on the leading side,
/// then Cancel next to the primary action on the trailing side, the primary last, as macOS places them.
///
///     FrogSheetButtons {
///         Button("Delete", role: .destructive) { … }.buttonStyle(.frog(.destructive))
///     } trailing: {
///         FrogCancelButton { dismiss() }
///         FrogPrimaryButton("Save", disabledReason: named ? nil : "Name the rule first") { save() }
///     }
///
/// A sheet whose whole content is already padded by `sheetPadding` passes `padded: false`, so the buttons keep the
/// same edge instead of doubling it.
struct FrogSheetButtons<Leading: View, Trailing: View>: View {
    var padded = true
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    init(padded: Bool = true, @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.padded = padded; self.leading = leading(); self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: FrogStyle.space8) {
            leading
            Spacer(minLength: FrogStyle.space8)
            trailing
        }
        .frogRowAccessory(false)
        .padding(.horizontal, padded ? FrogStyle.sheetPadding : 0).padding(.top, padded ? FrogStyle.space12 : 0)
        .padding(.bottom, padded ? FrogStyle.sheetPadding : 0)
    }
}

extension FrogSheetButtons where Leading == EmptyView {
    init(padded: Bool = true, @ViewBuilder trailing: () -> Trailing) {
        self.init(padded: padded, leading: { EmptyView() }, trailing: trailing)
    }
}

/// A sheet's Cancel: a secondary button that Escape presses.
struct FrogCancelButton: View {
    var title = "Cancel"
    let action: () -> Void
    init(_ title: String = "Cancel", action: @escaping () -> Void) { self.title = title; self.action = action }
    var body: some View {
        Button(L10n.text(title), action: action).buttonStyle(.frog()).keyboardShortcut(.cancelAction)
    }
}

/// A sheet's main action: the primary button that Return presses, disabled with its reason while it cannot run.
struct FrogPrimaryButton: View {
    let title: String
    var disabledReason: String? = nil
    let action: () -> Void
    init(_ title: String, disabledReason: String? = nil, action: @escaping () -> Void) {
        self.title = title; self.disabledReason = disabledReason; self.action = action
    }
    var body: some View {
        Button(L10n.text(title), action: action).buttonStyle(.frog(.primary)).keyboardShortcut(.defaultAction)
            .frogDisabled(disabledReason)
    }
}
