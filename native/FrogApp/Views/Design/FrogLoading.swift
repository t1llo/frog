import FrogCore
import SwiftUI

/// Frog's one spinner, sized for a row, a button or a pill: eight spokes in the text colour, the newest strongest,
/// stepping round as the system's spinner does. Drawn by Frog rather than `NSProgressIndicator`, whose dark spokes
/// all but vanished on dark panels, so it reads the same in every theme. Use it in place of a bare `ProgressView()`,
/// so every wait in Frog looks the same.
struct FrogSpinner: View {
    var size: ControlSize = .small
    var label = "Loading"

    /// Steps a second, and the spokes in the ring, as macOS turns its own.
    private static let rate = 10.0
    private static let spokes = 8

    private var diameter: CGFloat {
        switch size {
        case .mini: 10
        case .small: 16
        case .large, .extraLarge: 32
        default: 20
        }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1 / Self.rate)) { context in
            let step = Int(FrogClock.now(or: context.date).timeIntervalSinceReferenceDate * Self.rate) % Self.spokes
            ZStack {
                ForEach(0..<Self.spokes, id: \.self) { index in
                    // The spoke `step` points at is the newest; the ones behind it fade out.
                    let age = (step - index + Self.spokes) % Self.spokes
                    Capsule(style: .continuous).fill(FrogStyle.ink)
                        .frame(width: max(1.5, diameter * 0.13), height: diameter * 0.3)
                        .offset(y: -diameter * 0.35)
                        .rotationEffect(.degrees(Double(index) * 360 / Double(Self.spokes)))
                        .opacity(0.75 - Double(age) * 0.08)
                }
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement().accessibilityLabel(L10n.text(label)).accessibilityAddTraits(.updatesFrequently)
    }
}

/// A value that is still being measured: a soft bar the width of the number it stands for, at the height of the
/// text it replaces, so nothing moves when the value arrives. It does not shimmer: nothing in Frog animates
/// continuously. Put one where each value will be; say "Measuring…" once for the whole group at most.
struct FrogSkeleton: View {
    /// About the width of the value it stands for: 28 for "12 %", 56 for "3.2 GB".
    var width: CGFloat = 40
    /// The line height of the text it replaces; `FrogType.body` is about 16, `FrogType.title` about 24.
    var height: CGFloat = 12
    var body: some View {
        Capsule(style: .continuous).fill(FrogStyle.skeleton)
            .frame(width: width, height: height * 0.75)
            .frame(height: height)
            .accessibilityHidden(true)
    }
}

/// A short wait inside a card or list: the spinner and one muted line, on the content edge. For a whole empty
/// page that is still loading, centre it with `.frame(maxWidth: .infinity)`.
struct FrogLoadingNote: View {
    let text: String
    var body: some View {
        HStack(spacing: FrogStyle.space8) {
            FrogSpinner(label: text)
            Text(L10n.text(text)).font(FrogType.small).foregroundStyle(FrogStyle.muted)
        }
        .padding(.vertical, FrogStyle.space8)
        .accessibilityElement(children: .combine)
    }
}
