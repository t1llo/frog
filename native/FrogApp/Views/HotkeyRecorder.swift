import SwiftUI
import AppKit
import FrogCore

/// A focused native control consumes recording keystrokes without installing a global or local monitor.
struct HotkeyRecorder: View {
    @EnvironmentObject private var model: AppModel
    @Binding var hotkey: Hotkey?
    var showsClearButton = true
    var purpose: HotkeyManager.ShortcutPurpose = .rule
    @State private var recording = false
    /// Why the last key press was refused. Not private, so that a layout test can show one without pressing a key.
    @State var hint: String?
    @State private var id = UUID()

    var body: some View {
        // One view: a second one would land beside the recorder in the row that holds it.
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                Button {
                    recording.toggle(); hint = nil
                } label: {
                    ShortcutBadge(text: recording ? L10n.text("Press shortcut…") : hotkey.map(HotkeyManager.display) ?? L10n.text("Record shortcut"))
                }.buttonStyle(.plain).help(recording ? "Press a new shortcut, or Escape to cancel." : "Click to change shortcut")
                if showsClearButton && (hotkey != nil || recording) {
                    Button { hotkey = nil; recording = false; hint = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).accessibilityLabel("Clear shortcut")
                }
                if recording {
                    KeyCapture(recording: $recording, hotkey: $hotkey, hint: $hint, purpose: purpose)
                        .frame(width: 1, height: 1).accessibilityHidden(true)
                }
            }
            if let hint {
                // Rows give their control its one-line width, so the hint wraps only at a width of its own.
                Text(hint).font(.caption2).foregroundStyle(FrogStyle.warning).multilineTextAlignment(.trailing)
                    .frame(width: 220, alignment: .trailing).fixedSize(horizontal: false, vertical: true)
            }
        }.onChange(of: recording) { _, value in
            if value { model.beginShortcutRecording(id) }
            // The refusal belongs to the recording that showed it.
            else { hint = nil; model.endShortcutRecording(id) }
        }
            // A recorder that comes back on screen must not still claim to be recording.
            .onDisappear { recording = false; hint = nil; model.endShortcutRecording(id) }
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
