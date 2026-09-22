import SwiftUI
import AppKit
import FrogCore

/// A focused native control consumes recording keystrokes without installing a global or local monitor.
struct HotkeyRecorder: View {
    @EnvironmentObject private var model: AppModel
    @Binding var hotkey: Hotkey?
    @State private var recording = false
    @State private var hint: String?

    var body: some View {
        HStack(spacing: 10) {
            ShortcutBadge(text: recording ? "Press shortcut…" : hotkey.map(HotkeyManager.display) ?? "No shortcut")
                .frame(minWidth: 140, alignment: .leading)
            Spacer(minLength: 0)
            Button(recording ? "Cancel recording" : "Record shortcut") {
                recording.toggle(); hint = nil
            }
            .buttonStyle(FrogButtonStyle(primary: recording))
            Button("Clear") { hotkey = nil; recording = false; hint = nil }
                .disabled(hotkey == nil && !recording)
            if recording {
                KeyCapture(recording: $recording, hotkey: $hotkey, hint: $hint)
                    .frame(width: 1, height: 1).accessibilityHidden(true)
            }
        }.onChange(of: recording) { _, value in model.setShortcutRecording(value) }
            .onDisappear { if recording { model.setShortcutRecording(false) } }
        if let hint { InlineIssue(message: hint) }
    }
}

private struct KeyCapture: NSViewRepresentable {
    @Binding var recording: Bool
    @Binding var hotkey: Hotkey?
    @Binding var hint: String?

    func makeNSView(context: Context) -> CaptureView { CaptureView() }

    func updateNSView(_ view: CaptureView, context: Context) {
        view.onKey = { event in
            if event.keyCode == 53 { recording = false; return }
            guard !event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  let value = HotkeyManager.hotkey(from: event) else {
                hint = "Include Control, Option, or Command in your shortcut."
                return
            }
            hotkey = value; hint = nil; recording = false
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
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { window.makeFirstResponder(self) }
        }
        override func keyDown(with event: NSEvent) { onKey?(event) }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard window?.firstResponder === self else { return false }
            onKey?(event)
            return true
        }
        override func resignFirstResponder() -> Bool {
            // Avoid publishing SwiftUI state during native hierarchy updates.
            let callback = onBlur
            DispatchQueue.main.async { callback?() }
            return true
        }
    }
}
