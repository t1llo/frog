import AppKit

/// How a menu-bar meter draws its readings. LLM usage and System monitor share these looks.
enum MenuBarMeterStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    /// A percentage per reading.
    case numbers
    /// Five steps per reading, stacked; each step is 20%, lit or empty, never half lit.
    case segments
    /// A smooth bar per reading, stacked.
    case bars
    /// Upright bars side by side, each beside its label.
    case columns

    var id: Self { self }
    init(choice: String) { self = Self(rawValue: choice) ?? .numbers }
    var title: String {
        switch self {
        case .numbers: "Numbers"
        case .segments: "Steps"
        case .bars: "Bars"
        case .columns: "Columns"
        }
    }
}

enum MenuBarMeterPalette: String, CaseIterable, Identifiable, Codable, Sendable {
    /// The menu bar's own colour, like the system's icons.
    case clean
    /// Green, amber or red, by how full each meter is.
    case level
    /// Green to red along each meter.
    case spectrum

    var id: Self { self }
    init(choice: String) { self = Self(rawValue: choice) ?? .clean }
    var title: String {
        switch self {
        case .clean: "Clean"
        case .level: "Traffic light"
        case .spectrum: "Spectrum"
        }
    }
}

/// One reading in a meter: a short label such as "5h", "A" or "CPU" and how full it is.
struct MenuBarMeterRow: Equatable, Sendable {
    let label: String
    /// 0 to 1 in whole percents, so a change too small to see draws nothing; nil without a reading.
    let fraction: Double?
    /// The reading as text, for the numbers style: "37%", or "—" without one.
    let value: String
    let dimmed: Bool

    init(label: String, fraction: Double?, value: String? = nil, dimmed: Bool = false) {
        let fraction = fraction.flatMap { $0.isFinite ? (min(1, max(0, $0)) * 100).rounded() / 100 : nil }
        self.label = label
        self.fraction = fraction
        self.value = value ?? fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
        self.dimmed = dimmed
    }
}

/// Everything a meter image shows. Two equal faces draw the same image.
struct MenuBarMeterFace: Equatable, Sendable {
    var rows: [MenuBarMeterRow]
    var style: MenuBarMeterStyle
    var palette: MenuBarMeterPalette
    /// A reading that could not be refreshed stays readable but recedes.
    var dimmed = false
    /// Whether the menu bar is dark. Only colours depend on it; a clean meter is a template.
    var dark = false
}

/// Draws meters for the menu bar, 22 points high. A clean meter is a template image, so macOS
/// tints it like its own icons; a coloured one draws its text for the menu bar it is in.
enum MenuBarMeter {
    static let height: CGFloat = 22
    static let steps = 5
    /// At most this many readings fit in a meter.
    static let maximumRows = 3

    static func image(_ face: MenuBarMeterFace) -> NSImage {
        let rows = Array(face.rows.prefix(maximumRows))
        let ink = Ink(palette: face.palette, dark: face.dark)
        let layout: Layout
        switch face.style {
        case .numbers: layout = numbersLayout(rows)
        case .segments, .bars: layout = stackedLayout(rows, style: face.style)
        case .columns: layout = columnsLayout(rows)
        }
        let image = NSImage(size: NSSize(width: max(1, layout.width), height: height), flipped: true) { _ in
            layout.draw(rows, face, ink)
            return true
        }
        image.isTemplate = face.palette == .clean
        return image
    }

    // MARK: Colours

    struct Ink {
        let palette: MenuBarMeterPalette
        let dark: Bool
        /// Text and the empty part of a track. Black in a template, which macOS then tints.
        var base: NSColor { palette == .clean || !dark ? .black : .white }
        func text(_ strength: Double) -> NSColor { base.withAlphaComponent((palette == .clean ? 1 : dark ? 0.92 : 0.82) * strength) }
        func track(_ strength: Double) -> NSColor { base.withAlphaComponent((dark && palette != .clean ? 0.22 : 0.17) * strength) }

        /// The filled part of a meter `fraction` full, at `position` along it (0 to 1).
        /// A reading that recedes (stale, or not refreshed) is drawn in the menu bar's own grey rather than a faded
        /// colour, which would mix with the bar into salmon, beige or brown.
        func fill(fraction: Double, position: Double, strength: Double) -> NSColor {
            if strength < 1 { return base.withAlphaComponent(0.88 * strength) }
            switch palette {
            case .clean: return base.withAlphaComponent(0.88 * strength)
            case .level: return MenuBarMeter.level(fraction, dark: dark).withAlphaComponent(strength)
            case .spectrum: return MenuBarMeter.spectrum(position, dark: dark).withAlphaComponent(strength)
            }
        }
        /// Colour for a reading shown as a number; nil keeps the text colour.
        func value(_ fraction: Double?, strength: Double) -> NSColor {
            guard palette != .clean, let fraction else { return text(strength) }
            return fill(fraction: fraction, position: fraction, strength: strength)
        }
    }

    private static func rgb(_ red: Double, _ green: Double, _ blue: Double) -> NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
    private static func green(_ dark: Bool) -> NSColor { dark ? rgb(0.20, 0.84, 0.36) : rgb(0.13, 0.64, 0.29) }
    private static func lime(_ dark: Bool) -> NSColor { dark ? rgb(0.62, 0.88, 0.18) : rgb(0.42, 0.70, 0.08) }
    private static func yellow(_ dark: Bool) -> NSColor { dark ? rgb(1.00, 0.84, 0.04) : rgb(0.93, 0.68, 0.00) }
    private static func orange(_ dark: Bool) -> NSColor { dark ? rgb(1.00, 0.60, 0.04) : rgb(0.94, 0.46, 0.00) }
    private static func red(_ dark: Bool) -> NSColor { dark ? rgb(1.00, 0.29, 0.25) : rgb(0.89, 0.19, 0.16) }

    /// Green below 70%, amber below 90%, red from there, as Frog's own meters.
    static func level(_ fraction: Double, dark: Bool) -> NSColor {
        fraction < 0.7 ? green(dark) : fraction < 0.9 ? orange(dark) : red(dark)
    }

    /// The spectrum's five clean colours, one per step: green, lime, yellow, orange, red.
    static func spectrumStops(dark: Bool) -> [NSColor] { [green(dark), lime(dark), yellow(dark), orange(dark), red(dark)] }

    /// The spectrum's colour at `position` along a meter: the nearest of its clean stops, never a blend of two, which
    /// turns green and yellow into olive. Only a bar's gradient runs between them.
    static func spectrum(_ position: Double, dark: Bool) -> NSColor {
        let stops = spectrumStops(dark: dark)
        let index = Int((min(1, max(0, position)) * Double(stops.count - 1)).rounded())
        return stops[index]
    }

    // MARK: Layouts

    struct Layout {
        let width: CGFloat
        let draw: ([MenuBarMeterRow], MenuBarMeterFace, Ink) -> Void
    }

    private static func strength(_ row: MenuBarMeterRow, _ face: MenuBarMeterFace) -> Double {
        (face.dimmed ? 0.55 : 1) * (row.dimmed ? 0.5 : 1)
    }

    /// The smallest type a meter draws: the size the menu bar's own small captions use. Every label, in every
    /// style, is at least this; where a style has no room for it, it lays its readings out side by side instead.
    static let captionSize: CGFloat = 9
    private static let captionFont = NSFont.systemFont(ofSize: captionSize, weight: .bold)

    /// Label and value per row, each row on its own line; the value column fits "100%", so the
    /// item keeps its width as readings change. Three readings stand side by side, each label over its value.
    private static func numbersLayout(_ rows: [MenuBarMeterRow]) -> Layout {
        guard rows.count <= 2 else { return sideBySideLayout(rows, style: .numbers) }
        let single = rows.count <= 1
        let labelFont = captionFont
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: single ? 12 : 10, weight: .semibold)
        let labelWidth = ceil(rows.map { width($0.label, labelFont) }.max() ?? 0)
        let valueWidth = ceil(max(width("100%", valueFont), rows.map { width($0.value, valueFont) }.max() ?? 0))
        let pitch: CGFloat = single ? 22 : 10.5
        let top = (height - pitch * CGFloat(max(1, rows.count))) / 2
        return Layout(width: labelWidth + 3 + valueWidth) { rows, face, ink in
            for (index, row) in rows.enumerated() {
                let strength = strength(row, face)
                let middle = top + pitch * (CGFloat(index) + 0.5)
                draw(row.label, font: labelFont, color: ink.text(0.7 * strength), right: labelWidth, middle: middle)
                draw(row.value, font: valueFont, color: ink.value(row.fraction, strength: strength), right: labelWidth + 3 + valueWidth, middle: middle)
            }
        }
    }

    /// One meter per row, stacked, its label to the left. Three readings stand side by side instead, each label
    /// over its meter, since three stacked rows leave no room for a readable label.
    private static func stackedLayout(_ rows: [MenuBarMeterRow], style: MenuBarMeterStyle) -> Layout {
        guard rows.count <= 2 else { return sideBySideLayout(rows, style: style) }
        let count = max(1, rows.count)
        let thickness: CGFloat = count == 1 ? 7 : 5.5
        let gap: CGFloat = count == 1 ? 0 : 4
        let labelFont = captionFont
        let labelWidth = ceil(rows.map { width($0.label, labelFont) }.max() ?? 0)
        let trackWidth: CGFloat = 36
        let start = labelWidth > 0 ? labelWidth + 3 : 0
        let top = (height - thickness * CGFloat(count) - gap * CGFloat(count - 1)) / 2
        return Layout(width: start + trackWidth) { rows, face, ink in
            for (index, row) in rows.enumerated() {
                let strength = strength(row, face)
                let y = top + CGFloat(index) * (thickness + gap)
                draw(row.label, font: labelFont, color: ink.text(0.75 * strength), right: labelWidth, middle: y + thickness / 2)
                let track = NSRect(x: start, y: y, width: trackWidth, height: thickness)
                if style == .segments { drawSteps(row.fraction, in: track, ink: ink, strength: strength, vertical: false) }
                else { drawBar(row.fraction, in: track, ink: ink, strength: strength, vertical: false) }
            }
        }
    }

    /// Readings side by side, each its label on top and its value, steps or bar under it, centred in its slot.
    private static func sideBySideLayout(_ rows: [MenuBarMeterRow], style: MenuBarMeterStyle) -> Layout {
        let labelFont = captionFont
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        let meterWidth: CGFloat = 26, thickness: CGFloat = 5, spacing: CGFloat = 7
        let content = style == .numbers ? ceil(width("100%", valueFont)) : meterWidth
        let slots = rows.map { max(content, ceil(width($0.label, labelFont))) }
        let total = slots.reduce(0, +) + spacing * CGFloat(max(0, slots.count - 1))
        // The label's capitals and the reading under them, as one block centred on the bar.
        let labelMiddle: CGFloat = 6, readingMiddle: CGFloat = 15.5
        return Layout(width: total) { rows, face, ink in
            var x: CGFloat = 0
            for (index, row) in rows.enumerated() {
                let strength = strength(row, face)
                let slot = slots[index], centre = x + slot / 2
                draw(row.label, font: labelFont, color: ink.text(0.75 * strength), right: centre + width(row.label, labelFont) / 2, middle: labelMiddle)
                switch style {
                case .numbers:
                    draw(row.value, font: valueFont, color: ink.value(row.fraction, strength: strength),
                         right: centre + width(row.value, valueFont) / 2, middle: readingMiddle)
                default:
                    let track = NSRect(x: centre - meterWidth / 2, y: readingMiddle - thickness / 2, width: meterWidth, height: thickness)
                    if style == .segments { drawSteps(row.fraction, in: track, ink: ink, strength: strength, vertical: false) }
                    else { drawBar(row.fraction, in: track, ink: ink, strength: strength, vertical: false) }
                }
                x += slot + spacing
            }
        }
    }

    /// Upright bars side by side, each with its label to its left at the caption size: a caption under a bar would
    /// leave the bar too short and the label too small to read.
    private static func columnsLayout(_ rows: [MenuBarMeterRow]) -> Layout {
        let labelFont = captionFont
        let barWidth: CGFloat = 6, gap: CGFloat = 3, spacing: CGFloat = 7
        let labels = rows.map { ceil(width($0.label, labelFont)) }
        let slots = labels.map { ($0 > 0 ? $0 + gap : 0) + barWidth }
        let total = slots.reduce(0, +) + spacing * CGFloat(max(0, slots.count - 1))
        return Layout(width: total) { rows, face, ink in
            var x: CGFloat = 0
            for (index, row) in rows.enumerated() {
                let strength = strength(row, face)
                let track = NSRect(x: x + slots[index] - barWidth, y: 3, width: barWidth, height: 16)
                draw(row.label, font: labelFont, color: ink.text(0.75 * strength), right: x + labels[index], middle: height / 2)
                drawBar(row.fraction, in: track, ink: ink, strength: strength, vertical: true)
                x += slots[index] + spacing
            }
        }
    }

    // MARK: Drawing

    /// Five steps, each either lit in its clean colour or empty: the reading is rounded to the nearest step, and any
    /// reading above zero lights the first. A step is never half lit or see-through, which would mix its colour with
    /// the track into olive, brown or beige; the numbers style is there for the exact value.
    static func litSteps(_ fraction: Double?) -> Int {
        guard let fraction, fraction > 0 else { return 0 }
        return min(steps, max(1, Int((fraction * Double(steps)).rounded())))
    }

    private static func drawSteps(_ fraction: Double?, in track: NSRect, ink: Ink, strength: Double, vertical: Bool) {
        let gap: CGFloat = 1.5
        let length = ((vertical ? track.height : track.width) - gap * CGFloat(steps - 1)) / CGFloat(steps)
        let radius = min(2, (vertical ? track.width : track.height) / 2.5)
        let lit = litSteps(fraction)
        for step in 0..<steps {
            let offset = CGFloat(step) * (length + gap)
            let rect = vertical
                ? NSRect(x: track.minX, y: track.maxY - offset - length, width: track.width, height: length)
                : NSRect(x: track.minX + offset, y: track.minY, width: length, height: track.height)
            (step < lit ? ink.fill(fraction: fraction ?? 0, position: Double(step) / Double(steps - 1), strength: strength)
                        : ink.track(strength)).setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        }
    }

    /// A rounded track, filled as far as the reading goes. A spectrum fill shows the colours up to there.
    private static func drawBar(_ fraction: Double?, in track: NSRect, ink: Ink, strength: Double, vertical: Bool) {
        let radius = min(vertical ? track.width : track.height, 6) / 2
        ink.track(strength).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
        guard let fraction, fraction > 0 else { return }
        let minimum = vertical ? track.width : track.height
        let rect = vertical
            ? NSRect(x: track.minX, y: track.maxY - max(minimum, track.height * fraction), width: track.width, height: max(minimum, track.height * fraction))
            : NSRect(x: track.minX, y: track.minY, width: max(minimum, track.width * fraction), height: track.height)
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        if ink.palette == .spectrum, strength >= 1, let gradient = NSGradient(colors: MenuBarMeter.spectrumStops(dark: ink.dark)) {
            // The gradient spans the whole track, so a fuller bar reaches redder colours. Upright
            // bars start green at the bottom; in these flipped coordinates that is -90°.
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            gradient.draw(in: track, angle: vertical ? -90 : 0)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            ink.fill(fraction: fraction, position: fraction, strength: strength).setFill()
            path.fill()
        }
    }

    static func width(_ text: String, _ font: NSFont) -> CGFloat { (text as NSString).size(withAttributes: [.font: font]).width }

    /// Draws `text` right-aligned at `right`, its capitals centred on `middle` (flipped coordinates).
    private static func draw(_ text: String, font: NSFont, color: NSColor, right: CGFloat, middle: CGFloat) {
        guard !text.isEmpty else { return }
        let baseline = middle + font.capHeight / 2
        (text as NSString).draw(at: NSPoint(x: right - width(text, font), y: baseline - font.ascender),
                                withAttributes: [.font: font, .foregroundColor: color])
    }
}

extension NSAppearance {
    /// Whether this appearance, such as a status button's, is a dark one.
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua, .vibrantDark, .vibrantLight]).map { $0 == .darkAqua || $0 == .vibrantDark } ?? false }
}
