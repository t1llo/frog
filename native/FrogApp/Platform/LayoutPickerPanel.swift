import AppKit
import SwiftUI
import FrogCore

/// A small panel of layout tiles for the window that was in front. It takes the keyboard for
/// the arrows and the filter, but never activates Frog, so the target app stays in front.
/// Created once and reused: hidden, never released.
@MainActor
final class LayoutPickerPanel: ObservableObject {
    static let width: CGFloat = 420
    static let maximumHeight: CGFloat = 620

    @Published private(set) var picker = LayoutPickerModel(hotkeys: [:])
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            picker.setQuery(query)
            guard isVisible else { return }
            selectionChanged()
            fit()
        }
    }
    @Published private(set) var appName: String?
    @Published var status: String?
    @Published private(set) var height: CGFloat = 300
    /// Renewed on each opening, so the filter field takes the focus again.
    @Published private(set) var invocation = UUID()

    /// The selected layout changed; nil when the filter leaves none.
    var onSelect: ((WindowAction?) -> Void)?
    var onApply: ((WindowAction) -> Void)?
    /// Escape, a click outside or another app in front.
    var onClose: (() -> Void)?

    private var panel: FrogFloatingPanel?
    private var placement: PanelPlacement.Result?
    private var target: pid_t?
    private var lastSelection: WindowAction?
    private var monitor: Any?
    private var outside: Any?
    private var activation: NSObjectProtocol?

    var isVisible: Bool { panel?.isVisible == true }
    var window: NSWindow? { panel }

    /// Opens centered on `display` (a visible frame in Cocoa coordinates), else on the display
    /// with the pointer. `target` is the app whose window it arranges; another app coming to the
    /// front closes it.
    func show(appName: String?, status: String?, hotkeys: [WindowAction: Hotkey], target: pid_t?, display: CGRect?) {
        removeMonitors()
        query = ""
        picker = LayoutPickerModel(hotkeys: hotkeys)
        self.appName = appName
        self.status = status
        self.target = target
        lastSelection = nil
        invocation = UUID()

        let panel = self.panel ?? makePanel()
        let screens = panel.screensForPlacement()
        let pointer = NSEvent.mouseLocation
        let display = display ?? screens.first { $0.contains(pointer) } ?? screens.first ?? CGRect(x: 0, y: 0, width: 800, height: 600)
        height = measuredHeight(limit: display.height - 40)
        let anchor = CGRect(x: display.midX - Self.width / 2, y: display.midY + height / 2 + 8, width: Self.width, height: 0)
        let placed = PanelPlacement.place(size: CGSize(width: Self.width, height: height), anchor: anchor, pointer: pointer, screens: screens)
        placement = placed
        panel.show(at: placed.frame)
        panel.makeKey()
        installMonitors()
        selectionChanged()
    }

    func hide() {
        removeMonitors()
        panel?.orderOut(nil)
        lastSelection = nil
        target = nil
    }

    func select(_ action: WindowAction) {
        picker.select(action)
        selectionChanged()
    }

    func apply(_ action: WindowAction) {
        picker.select(action)
        onApply?(action)
    }

    private func move(_ direction: LayoutPickerModel.Direction) {
        picker.move(direction)
        selectionChanged()
    }

    private func close() { onClose?() }

    private func selectionChanged() {
        guard picker.selection != lastSelection else { return }
        lastSelection = picker.selection
        onSelect?(picker.selection)
    }

    /// Keeps the top edge where it is while the filter changes the height.
    private func fit() {
        guard let panel, let placement else { return }
        height = measuredHeight(limit: placement.screen.height - 40)
        let resized = PanelPlacement.resized(placement, height: height)
        self.placement = resized
        panel.setFrame(resized.frame, display: true)
    }

    private func measuredHeight(limit: CGFloat) -> CGFloat {
        let measured = NSHostingView(rootView: LayoutPickerView(panel: self, measuring: true)).fittingSize.height
        return min(Self.maximumHeight, max(160, limit), ceil(measured))
    }

    private func makePanel() -> FrogFloatingPanel {
        let panel = FrogFloatingPanel(size: CGSize(width: Self.width, height: height), allowsKey: true)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = FirstMouseHostingView(rootView: LayoutPickerView(panel: self))
        host.sizingOptions = []
        panel.contentView = host
        self.panel = panel
        return panel
    }

    // MARK: Keys and clicks

    private func installMonitors() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, let panel = self.panel else { return false }
                if event.type != .keyDown { if event.window !== panel { self.close() }; return false }
                guard event.window === panel else { return false }
                return self.handleKey(event)
            }
            return consumed ? nil : event
        }
        outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        activation = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.processIdentifier != ProcessInfo.processInfo.processIdentifier, app.processIdentifier != self.target else { return }
                self.close()
            }
        }
    }

    private func removeMonitors() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let outside { NSEvent.removeMonitor(outside) }
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
        monitor = nil; outside = nil; activation = nil
    }

    /// Return applies, Escape and ⌘W close, the arrows move in the grid; every other key goes
    /// to the filter field.
    private func handleKey(_ event: NSEvent) -> Bool {
        let composing = (panel?.firstResponder as? NSTextInputClient)?.hasMarkedText() == true
        let state = PanelState(queryIsEmpty: query.isEmpty, composing: composing)
        switch PanelKeyMap.decide(keyCode: event.keyCode, modifiers: event.panelModifiers, state: state) {
        case .runPrimary, .runSecondary, .runPlain:
            if let selection = picker.selection { onApply?(selection) }
            return true
        case .close, .closeActions, .clearQuery: close(); return true
        case .moveUp: move(.up); return true
        case .moveDown: move(.down); return true
        case .toggleActions, .runAction: return true
        case .pass:
            guard !composing, event.panelModifiers.isEmpty else { return false }
            switch event.keyCode {
            case 123: move(.left); return true
            case 124: move(.right); return true
            default: return false
            }
        }
    }
}

struct LayoutPickerView: View {
    @ObservedObject var panel: LayoutPickerPanel
    /// Laid out at its natural height, without scrolling, to size the panel.
    var measuring = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Arrange window").font(.system(size: 13, weight: .medium))
                    if let name = panel.appName {
                        Text(name).font(FrogType.body).foregroundStyle(FrogStyle.muted).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                TextField("Filter layouts", text: $panel.query)
                    .textFieldStyle(.plain).font(.system(size: 13)).focused($focused)
                    .padding(.horizontal, 8).frame(height: 28)
                    .background(FrogStyle.inset, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(FrogStyle.border.opacity(0.6)))
                if let status = panel.status {
                    Text(status).font(FrogType.caption).foregroundStyle(FrogStyle.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding([.horizontal, .top], 14).padding(.bottom, 10)
            if measuring { grid } else {
                ScrollViewReader { proxy in
                    ScrollView { grid }
                        .scrollIndicators(.never)
                        .onChange(of: panel.picker.selection) { _, selection in
                            if let selection { proxy.scrollTo(selection.rawValue) }
                        }
                }
            }
            PanelFooter(symbol: WindowCommand.layoutPicker.symbol, name: "Arrange window", primaryTitle: "Apply",
                        showsActions: false, closeTitle: "Close")
        }
        .frame(width: LayoutPickerPanel.width, height: measuring ? nil : panel.height, alignment: .top)
        .frogPanel()
        .foregroundStyle(FrogStyle.ink)
        .environment(\.locale, L10n.locale)
        .onAppear { focused = true }
        .onChange(of: panel.invocation) { focused = true }
    }

    private var grid: some View {
        VStack(alignment: .leading, spacing: 10) {
            if panel.picker.sections.isEmpty {
                Text("No matching layout").font(FrogType.body).foregroundStyle(FrogStyle.muted)
                    .frame(maxWidth: .infinity).padding(.vertical, 18)
            }
            ForEach(panel.picker.sections) { section in
                VStack(alignment: .leading, spacing: 4) {
                    Text(section.title).font(FrogType.label).foregroundStyle(FrogStyle.muted)
                    ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
                        let badges = row.contains { $0.hotkey != nil }
                        HStack(spacing: 6) {
                            ForEach(row) { tile in
                                LayoutPickerTile(tile: tile, selected: panel.picker.selection == tile.action, showsBadge: badges,
                                                 select: { panel.select(tile.action) }, apply: { panel.apply(tile.action) })
                            }
                            ForEach(row.count..<LayoutPickerModel.columns, id: \.self) { _ in
                                Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.bottom, 12)
    }
}

private struct LayoutPickerTile: View {
    let tile: LayoutPickerModel.Tile
    let selected: Bool
    let showsBadge: Bool
    let select: () -> Void
    let apply: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            WindowLayoutGlyph(action: tile.action, size: CGSize(width: 44, height: 28))
            Text(tile.title).font(.system(size: 11)).multilineTextAlignment(.center).lineLimit(2)
                .frame(height: 28, alignment: .top)
            if showsBadge {
                if let key = tile.hotkey { ShortcutBadge(text: HotkeyManager.display(key)) }
                else { Color.clear.frame(height: 24) }
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity)
        .background(selected ? FrogStyle.selection : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? FrogStyle.accent.opacity(0.6) : Color.clear))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onHover { if $0 { select() } }
        .onTapGesture(perform: apply)
        .id(tile.action.rawValue)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tile.title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { apply() }
    }
}
