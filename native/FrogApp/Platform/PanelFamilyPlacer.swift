import AppKit
import Combine
import FrogCore

/// Places the keyboard panels (command bar, clipboard history, window switcher) as one family, by
/// `PanelFamilyPlacement`, and keeps where the person dragged the family on each display in `panel-placement.json`
/// beside Frog's other data, so it survives relaunching. One placer per data folder: every panel of a Frog moves
/// together. Built without a folder (tests, previews) it remembers only while it lives.
@MainActor final class PanelFamilyPlacer: ObservableObject {
    /// Whether the panel shown last stands away from the default place on its display: its search line then offers
    /// to move the family back.
    @Published private(set) var placed = false
    private(set) var memory: PanelFamilyPlacement.Memory
    private let file: URL?
    /// The family panel placed or dragged last, which the search line's button moves back.
    private weak var shown: NSWindow?
    /// The displays and pointer, from AppKit; tests give their own.
    var displays: @MainActor () -> [PanelFamilyPlacement.Display] = { NSScreen.screens.map(PanelFamilyPlacer.display) }
    var pointer: @MainActor () -> CGPoint = { NSEvent.mouseLocation }

    private static var shared: [URL: PanelFamilyPlacer] = [:]

    /// The placer of the Frog whose data is in `directory`.
    static func shared(in directory: URL) -> PanelFamilyPlacer {
        let file = directory.appendingPathComponent("panel-placement.json")
        if let placer = shared[file] { return placer }
        let placer = PanelFamilyPlacer(file: file)
        shared[file] = placer
        return placer
    }

    init(file: URL? = nil) {
        self.file = file
        memory = file.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(PanelFamilyPlacement.Memory.self, from: $0) } ?? .init()
    }

    /// Puts `window` at `size` where the family opens: on the display under the pointer, at its place there.
    func place(_ window: NSWindow, size: CGSize) {
        let displays = displays()
        guard let frame = PanelFamilyPlacement.opening(size: size, pointer: pointer(), displays: displays, memory: memory) else {
            window.setContentSize(size); window.center(); return
        }
        if window.frame != frame { window.setFrame(frame, display: true) }
        shown = window
        placed = PanelFamilyPlacement.isPlaced(frame, displays: displays, memory: memory)
    }

    /// Gives `window` a new size, keeping its top centre: only the bottom edge moves.
    func resize(_ window: NSWindow, to size: CGSize) {
        guard window.frame.size != size else { return }
        window.setFrame(PanelFamilyPlacement.resized(window.frame, to: size, displays: displays()), display: true)
    }

    /// The end of a drag of any family panel (`WindowDragRegion` calls it once the window moved): remembers the
    /// family's new place on that display, or snaps it home when the drag ended near the default place.
    func finishDrag(_ window: NSWindow) {
        let drag = PanelFamilyPlacement.finishDrag(window.frame, displays: displays(), memory: memory)
        if window.frame != drag.frame { window.setFrame(drag.frame, display: true) }
        shown = window
        placed = drag.placed
        save(drag.memory)
    }

    /// Moves the family back to its default place on the display `window` is on.
    func reset(_ window: NSWindow) {
        let reset = PanelFamilyPlacement.reset(window.frame, displays: displays(), memory: memory)
        if window.frame != reset.frame { window.setFrame(reset.frame, display: true) }
        placed = false
        save(reset.memory)
    }

    /// The search line's button: the panel on screen goes back to the default place.
    func resetShown() { if let shown { reset(shown) } }

    private func save(_ next: PanelFamilyPlacement.Memory) {
        guard next != memory else { return }
        memory = next
        guard let file else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(next).write(to: file, options: .atomic)
        } catch {
            // The place is still kept while Frog runs; only relaunching forgets it.
        }
    }

    /// A display as the placement knows it: its UUID, which stays the same across launches and rearranging.
    static func display(_ screen: NSScreen) -> PanelFamilyPlacement.Display {
        let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        var id = number.map { "display-\($0)" } ?? screen.localizedName
        if let number, let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue(),
           let text = CFUUIDCreateString(nil, uuid) as String? {
            id = text
        }
        return .init(id: id, frame: screen.frame, visibleFrame: screen.visibleFrame)
    }
}
