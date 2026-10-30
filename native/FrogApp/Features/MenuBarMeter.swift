import AppKit

/// How a menu-bar meter draws its readings. LLM usage and System monitor share these looks.
enum MenuBarMeterStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    /// A percentage per reading.
    case numbers
    /// Five steps per reading, stacked; each step is 20%.
    case segments
    /// A smooth bar per reading, stacked.
    case bars
    /// Upright bars side by side.
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
        func fill(fraction: Double, position: Double, strength: Double) -> NSColor {
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
    private static func yellow(_ dark: Bool) -> NSColor { dark ? rgb(1.00, 0.84, 0.04) : rgb(0.85, 0.63, 0.00) }
    private static func orange(_ dark: Bool) -> NSColor { dark ? rgb(1.00, 0.60, 0.04) : rgb(0.94, 0.46, 0.00) }
    private static func red(_ dark: Bool) -> NSColor { dark ? rgb(1.00, 0.29, 0.25) : rgb(0.89, 0.19, 0.16) }

    /// Green below 70%, amber below 90%, red from there, as Frog's own meters.
    static func level(_ fraction: Double, dark: Bool) -> NSColor {
        fraction < 0.7 ? green(dark) : fraction < 0.9 ? orange(dark) : red(dark)
    }

    /// Green at the start of a meter, through yellow and orange, to red at its end.
    static func spectrum(_ position: Double, dark: Bool) -> NSColor {
        let stops: [(Double, NSColor)] = [(0, green(dark)), (0.5, yellow(dark)), (0.75, orange(dark)), (1, red(dark))]
        let position = min(1, max(0, position))
        for (lower, upper) in zip(stops, stops.dropFirst()) where position <= upper.0 {
            let amount = (position - lower.0) / (upper.0 - lower.0)
            return lower.1.blended(withFraction: amount, of: upper.1) ?? lower.1
        }
        return red(dark)
    }

    // MARK: Layouts

    struct Layout {
        let width: CGFloat
        let draw: ([MenuBarMeterRow], MenuBarMeterFace, Ink) -> Void
    }

    private static func strength(_ row: MenuBarMeterRow, _ face: MenuBarMeterFace) -> Double {
        (face.dimmed ? 0.55 : 1) * (row.dimmed ? 0.5 : 1)
    }

    /// Label and value per row, each row on its own line; the value column fits "100%", so the
    /// item keeps its width as readings change.
    private static func numbersLayout(_ rows: [MenuBarMeterRow]) -> Layout {
        let single = rows.count <= 1
        let crowded = rows.count >= 3
        let labelFont = NSFont.systemFont(ofSize: single ? 9 : crowded ? 5.5 : 7.5, weight: .bold)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: single ? 12 : crowded ? 6.5 : 9.5, weight: .semibold)
        let labelWidth = ceil(rows.map { width($0.label, labelFont) }.max() ?? 0)
        let valueWidth = ceil(max(width("100%", valueFont), rows.map { width($0.value, valueFont) }.max() ?? 0))
        let pitch: CGFloat = single ? 22 : rows.count == 2 ? 10 : 7
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

    /// One meter per row, stacked, its label to the left.
    private static func stackedLayout(_ rows: [MenuBarMeterRow], style: MenuBarMeterStyle) -> Layout {
        let count = max(1, rows.count)
        let thickness: CGFloat = count == 1 ? 7 : count == 2 ? 5.5 : 4
        let gap: CGFloat = count == 1 ? 0 : count == 2 ? 4 : 2.5
        let labelFont = NSFont.systemFont(ofSize: count >= 3 ? 6.5 : 8, weight: .bold)
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

    /// Upright bars side by side, each with its label beneath.
    private static func columnsLayout(_ rows: [MenuBarMeterRow]) -> Layout {
        let labelFont = NSFont.systemFont(ofSize: 6.5, weight: .bold)
        let barWidth: CGFloat = 6, spacing: CGFloat = 4
        let slots = rows.map { max(barWidth + 2, ceil(width($0.label, labelFont))) }
        let total = slots.reduce(0, +) + spacing * CGFloat(max(0, slots.count - 1))
        return Layout(width: total) { rows, face, ink in
            var x: CGFloat = 0
            for (index, row) in rows.enumerated() {
                let strength = strength(row, face)
                let slot = slots[index]
                let track = NSRect(x: x + (slot - barWidth) / 2, y: 1.5, width: barWidth, height: 13)
                drawBar(row.fraction, in: track, ink: ink, strength: strength, vertical: true)
                let labelWidth = width(row.label, labelFont)
                // Baseline at 21, so the caps sit just under the bar.
                (row.label as NSString).draw(at: NSPoint(x: x + (slot - labelWidth) / 2, y: 21 - labelFont.ascender),
                                             withAttributes: [.font: labelFont, .foregroundColor: ink.text(0.75 * strength)])
                x += slot + spacing
            }
        }
    }

    // MARK: Drawing

    /// Five steps; each lights fully once its 20% is reached, and the step in progress glows faintly.
    private static func drawSteps(_ fraction: Double?, in track: NSRect, ink: Ink, strength: Double, vertical: Bool) {
        let gap: CGFloat = 1.5
        let length = ((vertical ? track.height : track.width) - gap * CGFloat(steps - 1)) / CGFloat(steps)
        let radius = min(2, (vertical ? track.width : track.height) / 2.5)
        let filled = (fraction ?? 0) * Double(steps)
        for step in 0..<steps {
            let offset = CGFloat(step) * (length + gap)
            let rect = vertical
                ? NSRect(x: track.minX, y: track.maxY - offset - length, width: track.width, height: length)
                : NSRect(x: track.minX + offset, y: track.minY, width: length, height: track.height)
            let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            let lit = min(1, max(0, filled - Double(step)))
            let color = ink.fill(fraction: fraction ?? 0, position: Double(step) / Double(steps - 1), strength: strength)
            if lit >= 0.999 { color.setFill() }
            else if lit > 0.001 { ink.track(strength).setFill(); path.fill(); color.withAlphaComponent(color.alphaComponent * 0.4).setFill() }
            else { ink.track(strength).setFill() }
            path.fill()
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
        if ink.palette == .spectrum, let gradient = NSGradient(colors: stride(from: 0.0, through: 1.0, by: 0.25).map {
            ink.fill(fraction: fraction, position: $0, strength: strength)
        }) {
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
