import AppKit
import Combine
import FrogCore

/// A cup in the menu bar while Stay awake is on, when its menu-bar icon is chosen. Its menu says
/// until when and turns Stay awake off.
@MainActor final class StayAwakeStatusItemController: NSObject, NSMenuDelegate {
    private let power: StayAwakeController
    private let openSettings: () -> Void
    private var style: String
    private var item: NSStatusItem?
    private var observation: AnyCancellable?
    private var updateTask: Task<Void, Never>?
    private var timer: Timer?
    private var shownFace: StayAwakeIcon.Face?
    var isShown: Bool { item?.isVisible == true }

    init(power: StayAwakeController, style: String, openSettings: @escaping () -> Void) {
        self.power = power; self.style = style; self.openSettings = openSettings
        super.init()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "Frog.StayAwake"
        item.isVisible = false
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        self.item = item
        observation = power.objectWillChange.sink { [weak self] _ in
            // ObservableObject emits before mutation; draw the new state after it.
            self?.updateTask?.cancel()
            self?.updateTask = Task { @MainActor [weak self] in
                guard !Task.isCancelled else { return }
                self?.update()
            }
        }
        update()
    }

    func apply(style: String) {
        guard self.style != style else { return }
        self.style = style
        update()
    }

    func stop() {
        observation?.cancel(); observation = nil
        updateTask?.cancel(); updateTask = nil
        timer?.invalidate(); timer = nil
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
    }

    private func update() {
        guard let item else { return }
        let on = power.hasReadState && power.isEnabled
        if item.isVisible != on { item.isVisible = on }
        guard on else { timer?.invalidate(); timer = nil; shownFace = nil; return }
        // The ring and the time left move on their own while a timed session runs.
        if power.deadline != nil, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.update() }
            }
            timer?.tolerance = 5
        } else if power.deadline == nil { timer?.invalidate(); timer = nil }
        let face = StayAwakeIcon.Face(style: style, deadline: power.deadline, duration: power.duration.rawValue)
        if face != shownFace { item.button?.image = StayAwakeIcon.image(face); shownFace = face }
        let description = Self.description(power)
        item.button?.toolTip = description
        item.button?.setAccessibilityLabel(description)
    }

    static func description(_ power: StayAwakeController, now: Date = Date()) -> String {
        guard let deadline = power.deadline else { return power.ownsSession ? "Stay awake is on until Frog quits" : "Stay awake is on outside Frog" }
        return "Stay awake is on until \(deadline.formatted(date: .omitted, time: .shortened))"
            + (StayAwakeIcon.left(until: deadline, now: now).map { " · \($0) left" } ?? "")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let title = NSMenuItem(title: Self.description(power), action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        let off = NSMenuItem(title: L10n.text("Turn off Stay awake"), action: #selector(turnOff), keyEquivalent: "")
        off.target = self
        off.isEnabled = power.canSwitch
        menu.addItem(off)
        let settings = NSMenuItem(title: L10n.text("Stay awake settings…"), action: #selector(showSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
    }

    @objc private func turnOff() { power.setEnabled(false) }
    @objc private func showSettings() { openSettings() }

    isolated deinit { stop() }
}

/// The Stay awake icon: a steaming cup, alone, inside a ring that drains as a timed session runs
/// out, or beside the time left. A template image, so macOS tints it like its own icons.
enum StayAwakeIcon {
    struct Face: Equatable {
        let style: String
        /// What is left of a timed session, 0 to 1 in steps of 2%; 1 for one until Frog quits.
        let remaining: Double
        /// "3h 42m", "42m"; nil for a session without an end or a style without text.
        let text: String?

        init(style: String, deadline: Date?, duration: TimeInterval, now: Date = Date()) {
            self.style = StayAwakePreferences.menuBarStyles.contains(style) ? style : "ring"
            if let deadline {
                let left = max(0, deadline.timeIntervalSince(now))
                // A session restored after a restart may have begun with another duration.
                let total = max(duration, left, 1)
                remaining = (left / total * 50).rounded(.up) / 50
            } else {
                remaining = 1
            }
            text = self.style == "time" ? deadline.flatMap { StayAwakeIcon.left(until: $0, now: now) } : nil
        }
    }

    /// "3h 42m" or "42m" until `deadline`, at least "1m"; nil once it has passed.
    static func left(until deadline: Date, now: Date = Date()) -> String? {
        let minutes = Int((deadline.timeIntervalSince(now) / 60).rounded(.up))
        guard minutes > 0 else { return nil }
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    static func image(_ face: Face) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let ring = face.style == "ring"
        let iconWidth: CGFloat = ring ? 20 : 18
        let textWidth = face.text.map { ceil(($0 as NSString).size(withAttributes: [.font: font]).width) + 3 } ?? 0
        let symbolSize: CGFloat = ring ? 9.5 : 13.5
        let configuration = NSImage.SymbolConfiguration(pointSize: symbolSize, weight: ring ? .bold : .semibold)
        let symbol = (NSImage(systemSymbolName: "cup.and.heat.waves.fill", accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: nil))?.withSymbolConfiguration(configuration)
        let image = NSImage(size: NSSize(width: iconWidth + textWidth, height: 22), flipped: false) { _ in
            let center = NSPoint(x: iconWidth / 2, y: 11)
            if ring {
                let radius: CGFloat = 8.25
                let track = NSBezierPath()
                track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
                track.lineWidth = 1.75
                NSColor.black.withAlphaComponent(0.22).setStroke()
                track.stroke()
                // Clockwise from twelve o'clock; what has run out is the gap behind it.
                let arc = NSBezierPath()
                arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * face.remaining, clockwise: true)
                arc.lineWidth = 1.75
                arc.lineCapStyle = .round
                NSColor.black.setStroke()
                if face.remaining > 0 { arc.stroke() }
            }
            if let symbol {
                let size = symbol.size
                symbol.draw(in: NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2 + (ring ? 0.25 : 0),
                                       width: size.width, height: size.height))
            }
            if let text = face.text {
                // Capitals centred on the cup: the point is the line's bottom, a descender below the baseline.
                (text as NSString).draw(at: NSPoint(x: iconWidth + 3, y: 11 - font.capHeight / 2 + font.descender),
                                        withAttributes: [.font: font, .foregroundColor: NSColor.black])
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
