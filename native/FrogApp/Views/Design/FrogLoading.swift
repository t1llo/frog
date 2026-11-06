import SwiftUI

/// Frog's one spinner: the system's small indeterminate circle, sized for a row, a button or a pill. Use it in
/// place of a bare `ProgressView()`, so every wait in Frog looks the same.
struct FrogSpinner: View {
    var size: ControlSize = .small
    var label = "Loading"
    var body: some View {
        ProgressView().progressViewStyle(.circular).controlSize(size)
            .accessibilityLabel(L10n.text(label))
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
        Capsule(style: .continuous).fill(FrogStyle.control)
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

extension View {
    /// Shows skeleton bars in place of this view's text while `loading` is true, keeping its size. For a value
    /// whose final width is known only roughly: `Text(value).frogSkeleton(loading, width: 48)`.
    @ViewBuilder func frogSkeleton(_ loading: Bool, width: CGFloat = 40, height: CGFloat = 12) -> some View {
        if loading { FrogSkeleton(width: width, height: height) } else { self }
    }
}
