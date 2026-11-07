import AppKit
import SwiftUI

/// The last line of Stay awake's duration list: a number, minutes or hours, and Return to make it the duration.
struct StayAwakeCustomDuration: View {
    /// The custom length in use, which picks the unit the field starts in.
    let current: Int
    let choose: (Int) -> Void
    @State private var text = ""
    @State private var hours: Bool
    @FocusState private var focused: Bool

    init(current: Int, choose: @escaping (Int) -> Void) {
        self.current = current; self.choose = choose
        _hours = State(initialValue: current % 60 == 0)
    }

    var body: some View {
        HStack(spacing: FrogStyle.space6) {
            FrogTextField(placeholder: "Custom", text: $text)
                .font(FrogType.body)
                .focused($focused)
                .onSubmit(submit)
                // Whole numbers only; anything else typed or pasted is dropped.
                .onChange(of: text) { _, value in
                    let digits = String(value.filter(\.isNumber).prefix(5))
                    if digits != value { text = digits }
                }
                .padding(.horizontal, FrogStyle.space8)
                .frogControlSurface(height: FrogStyle.compactHeight)
                .accessibilityLabel("Custom duration")
                .accessibilityHint("Type a number and press Return")
            CompactSegments(values: [false, true], selected: hours, compact: true,
                            title: { $0 ? "h" : "min" }) { hours = $0 }
                .fixedSize()
                .accessibilityLabel("Unit")
        }
        .help("Type how long, choose minutes or hours, and press Return.")
    }

    private func submit() {
        guard let minutes = StayAwakeController.customMinutes(text, hours: hours) else { NSSound.beep(); return }
        choose(minutes)
    }
}
