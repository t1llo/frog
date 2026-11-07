import SwiftUI
import AppKit
import FrogCore

/// A focused native control consumes recording keystrokes without installing a global or local monitor.
struct HotkeyRecorder: View {
    @EnvironmentObject private var model: AppModel
    @Binding var hotkey: Hotkey?
    var showsClearButton = true
    var purpose: HotkeyManager.ShortcutPurpose = .rule
    /// What the button says while there is no shortcut; a grid of many says less.
    var emptyTitle = "Record shortcut"
    /// How a recorder with no shortcut looks at rest. `.button` (the default) shows the Record shortcut pill;
    /// `.placeholder` shows a quiet dash and reveals the pill only while the pointer is over the recorder or its row
    /// (`frogRevealsRecorder()`), or the recorder has keyboard focus, for lists where many slots stay empty.
    var unset: Unset = .button
    /// Told when a recording starts and ends, such as for a row that keeps a pointed-at control in view.
    var recordingChanged: (Bool) -> Void = { _ in }
    @State private var recording = false
    @State private var hovering = false
    @State private var hoveringClear = false
    /// Why the last key press was refused. Not private, so that a layout test can show one without pressing a key.
    @State var hint: String?
    @State private var id = UUID()
    @FocusState private var focused: Bool
    @Environment(\.frogRecorderRevealed) private var rowRevealed
    @Environment(\.frogKeyboardSurface) private var keyboardSurface

    enum Unset { case button, placeholder }

    /// The quiet look: nothing recorded, not recording, and nothing points at it.
    private var quiet: Bool {
        unset == .placeholder && hotkey == nil && !recording && !hovering && !rowRevealed && !focused
    }

    var body: some View {
        // One view: a second one would land beside the recorder in the row that holds it.
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                let text = recording ? L10n.text("Press shortcut…") : hotkey.map(HotkeyManager.display) ?? L10n.text(emptyTitle)
                // One button whose label changes, so keyboard focus stays on it when a recording starts from
                // the keyboard. A recorded shortcut is caps, one per key, as everywhere else Frog shows one;
                // recording, or nothing recorded yet, is a secondary button in the sans font.
                let caps = recording ? nil : hotkey
                Button { recording.toggle(); hint = nil } label: {
                    if let caps { RecordedKeys(hotkey: caps) } else { Text(text) }
                }.buttonStyle(RecorderButtonStyle(caps: caps != nil))
                    .focused($focused)
                    // An empty slot in a long list rests as a faint dash on the trailing edge, where caps would end;
                    // the pill keeps its room, so nothing moves when it shows.
                    .opacity(quiet ? 0 : 1)
                    .overlay(alignment: .trailing) {
                        if quiet {
                            Text(verbatim: "–").font(FrogType.body).foregroundStyle(FrogStyle.placeholder)
                                .allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
                    .animation(FrogMotion.hover(!quiet, keyboardSurface: keyboardSurface), value: quiet)
                    .accessibilityLabel("Shortcut: \(text)")
                    .accessibilityActions {
                        if clearable { Button(L10n.text("Clear shortcut"), action: clear) }
                    }
                    .help(recording ? "Press a new shortcut, or Escape to cancel." : "Click to change shortcut")
                    // The clear button shows in the row's free space before the caps while the pointer is over the
                    // recorder or it records, so the caps stay on the row's trailing edge and never move. It
                    // reaches the caps with its own hit area, so the pointer can cross to it.
                    .overlay(alignment: .leading) {
                        if clearable {
                            Button(action: clear) {
                                Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(FrogStyle.muted)
                                    .padding(.trailing, FrogStyle.space6).frame(height: FrogStyle.compactHeight).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).help(L10n.text("Clear shortcut")).accessibilityHidden(true)
                            .onHover { hoveringClear = $0 }
                            .fixedSize().alignmentGuide(.leading) { $0[.trailing] }
                            .opacity(hovering || hoveringClear || recording ? 1 : 0)
                        }
                    }
                if recording {
                    KeyCapture(recording: $recording, hotkey: $hotkey, hint: $hint, purpose: purpose)
                        .frame(width: 1, height: 1).accessibilityHidden(true)
                }
            }
            .onHover { hovering = $0 }
            if let hint {
                // Rows give their control its one-line width, so the hint wraps only at a width of its own.
                Text(hint).font(FrogType.caption).foregroundStyle(FrogStyle.warning).multilineTextAlignment(.trailing)
                    .frame(width: 220, alignment: .trailing).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: recording) { _, value in
            recordingChanged(value)
            if value { model.beginShortcutRecording(id) }
            // The refusal belongs to the recording that showed it.
            else { hint = nil; model.endShortcutRecording(id) }
        }
            // A recorder that comes back on screen must not still claim to be recording.
            .onDisappear { recording = false; hint = nil; model.endShortcutRecording(id) }
    }

    /// How far the hover clear button reaches before the caps. A narrow row keeps at least this much free before its
    /// recorder, so the button never lands on the row's title.
    static let clearButtonRoom: CGFloat = 13 + FrogStyle.space6 + FrogStyle.space4

    private var clearable: Bool { showsClearButton && (hotkey != nil || recording) }
    private func clear() { hotkey = nil; recording = false; hint = nil }
}

private struct FrogRecorderRevealedKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// True while the pointer is over a row marked `frogRevealsRecorder()`: its `HotkeyRecorder(unset: .placeholder)`
    /// shows its Record shortcut pill instead of the quiet dash.
    var frogRecorderRevealed: Bool {
        get { self[FrogRecorderRevealedKey.self] }
        set { self[FrogRecorderRevealedKey.self] = newValue }
    }
}

extension View {
    /// Marks a row whose `HotkeyRecorder(unset: .placeholder)` shows its Record shortcut pill while the pointer is
    /// anywhere over the row, not only over the dash.
    func frogRevealsRecorder() -> some View { modifier(RecorderRevealRow()) }
}

private struct RecorderRevealRow: ViewModifier {
    @State private var hovering = false
    func body(content: Content) -> some View {
        content.environment(\.frogRecorderRevealed, hovering).onHover { hovering = $0 }
    }
}

/// Plain for the recorded caps, which draw their own hover; Frog's secondary button for text.
private struct RecorderButtonStyle: ButtonStyle {
    let caps: Bool
    @ViewBuilder func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        if caps { configuration.label.opacity(configuration.isPressed ? 0.7 : 1) }
        else { FrogButtonStyle.frog().makeBody(configuration: configuration) }
    }
}

/// Not private, so that a test can end a recording without showing a window.
struct KeyCapture: NSViewRepresentable {
    @Binding var recording: Bool
    @Binding var hotkey: Hotkey?
    @Binding var hint: String?
    let purpose: HotkeyManager.ShortcutPurpose

    func makeNSView(context: Context) -> CaptureView { CaptureView() }

    func updateNSView(_ view: CaptureView, context: Context) {
        view.onKey = { event in
            if event.keyCode == 53 { recording = false; return }
            guard let result = HotkeyManager.capture(event, purpose: purpose) else { return }
            switch result {
            case .success(let value): hotkey = value; hint = nil; recording = false
            case .failure(let error): hint = error.localizedDescription
            }
        }
        view.onBlur = { recording = false }
    }

    static func dismantleNSView(_ view: CaptureView, coordinator: ()) {
        view.onKey = nil; view.onBlur = nil
        if view.window?.firstResponder === view { view.window?.makeFirstResponder(nil) }
    }

    final class CaptureView: NSView {
        var onKey: ((NSEvent) -> Void)?
        var onBlur: (() -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.makeFirstResponder(self)
            // Switching apps, closing or minimizing the window keeps this view first responder
            // of a window that gets no keys, while every Frog shortcut stays off for the recording.
            NotificationCenter.default.addObserver(self, selector: #selector(windowResignedKey), name: NSWindow.didResignKeyNotification, object: window)
        }
        @objc private func windowResignedKey(_ notification: Notification) {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window?.isKeyWindow != true else { return }
                self.onBlur?()
            }
        }
        override func keyDown(with event: NSEvent) { onKey?(event) }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard window?.firstResponder === self else { return false }
            onKey?(event)
            return true
        }
        override func resignFirstResponder() -> Bool {
            // Avoid publishing SwiftUI state during native hierarchy updates.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window?.firstResponder !== self else { return }
                self.onBlur?()
            }
            return true
        }
    }
}

/// A recorded shortcut in a `HotkeyRecorder`: its caps on a faint hover fill, so they read as the control they are.
private struct RecordedKeys: View {
    let hotkey: Hotkey
    @State private var hovering = false
    @Environment(\.frogKeyboardSurface) private var keyboardSurface
    @Environment(\.frogRowAccessory) private var inRow
    var body: some View {
        KeyCaps(hotkey: hotkey)
            .padding(.horizontal, FrogStyle.space4).frame(height: FrogStyle.compactHeight)
            .background {
                Capsule(style: .continuous).fill(hovering ? FrogStyle.hover : .clear)
                    .animation(FrogMotion.hover(hovering, keyboardSurface: keyboardSurface), value: hovering)
            }
            .contentShape(Capsule())
            .onHover { hovering = $0 }
            // In a row the last cap ends on the content edge, as a switch or button does; only the hover fill
            // reaches past it.
            .padding(.trailing, inRow ? -FrogStyle.space4 : 0)
    }
}
