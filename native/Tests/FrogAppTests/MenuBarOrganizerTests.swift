import AppKit
import XCTest
import FrogCore
@testable import FrogApp

@MainActor final class MenuBarOrganizerTests: XCTestCase {
    func testSpacerResizeDoesNotReopenDuringWindowServerLayout() {
        let fixture = OrganizerFixture()
        fixture.organizer.configure(enabled: true, settings: MenuBarPreferences())
        fixture.items.delaysLayout = true
        fixture.organizer.toggle()
        XCTAssertFalse(fixture.organizer.isExpanded)
        fixture.organizer.tick()
        XCTAssertFalse(fixture.organizer.isExpanded, "New width at the old origin is a pending layout, not a reversed divider")
        fixture.organizer.configure(enabled: true, settings: MenuBarPreferences())
        XCTAssertFalse(fixture.organizer.isExpanded, "Preference reapplication must respect the same layout transition")
        XCTAssertNil(fixture.organizer.issue)
        fixture.items.settleLayout()
        fixture.time = 0.5
        fixture.organizer.tick()
        XCTAssertFalse(fixture.organizer.isExpanded)
        fixture.time = 2
        fixture.organizer.tick()
        XCTAssertFalse(fixture.organizer.isExpanded)
    }

    func testUnsettledUnsafeGeometryStillRecoversAfterBoundedGrace() {
        let fixture = OrganizerFixture()
        fixture.organizer.configure(enabled: true, settings: MenuBarPreferences())
        fixture.items.delaysLayout = true
        fixture.organizer.toggle()
        fixture.time = 2
        fixture.organizer.tick()
        XCTAssertTrue(fixture.organizer.isExpanded)
        XCTAssertNotNil(fixture.organizer.issue)
    }

    func testNativeContextMenuHasRevealArrangementAndCheckedAutoHide() throws {
        _ = NSApplication.shared
        let adapter = NativeOrganizerStatusItems()
        var changedAutoHide = false
        adapter.updateMenu(OrganizerMenuState(expanded: false, arranging: false, autoHide: true)) { action in
            if case .autoHide = action { changedAutoHide = true }
        }
        XCTAssertEqual(adapter.contextMenu.items.filter { !$0.isSeparatorItem }.map(\.title),
                       ["Show hidden icons", "Show all & arrange…", "Automatically hide icons", "Menu bar settings…"])
        let autoHide = try XCTUnwrap(adapter.contextMenu.items.first { $0.title == "Automatically hide icons" })
        XCTAssertEqual(autoHide.state, .on)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(autoHide.action), to: autoHide.target, from: autoHide))
        XCTAssertTrue(changedAutoHide)
        adapter.updateMenu(OrganizerMenuState(expanded: true, arranging: true, autoHide: false)) { _ in }
        XCTAssertEqual(adapter.contextMenu.items[0].title, "Hide menu bar icons")
        XCTAssertEqual(adapter.contextMenu.items[1].title, "Done arranging")
        XCTAssertEqual(adapter.contextMenu.items[3].state, .off)
        XCTAssertTrue(NativeOrganizerStatusItems.arrowImage(expanded: true).isTemplate)
    }

    func testContextMenuDefersAutoHideAndItsChangesGoThroughPersistence() {
        let fixture = OrganizerFixture()
        var settings = MenuBarPreferences(); settings.autoHideSeconds = 5
        fixture.organizer.onSettingsChange = { value in
            settings = value
            fixture.organizer.configure(enabled: true, settings: value)
        }
        fixture.organizer.configure(enabled: true, settings: settings)
        fixture.items.menuAction?(.tracking(true))
        fixture.time = 20; fixture.organizer.tick()
        XCTAssertTrue(fixture.organizer.isExpanded)
        fixture.items.menuAction?(.tracking(false))
        fixture.time = 24; fixture.organizer.tick()
        XCTAssertTrue(fixture.organizer.isExpanded)
        fixture.time = 25; fixture.organizer.tick()
        XCTAssertFalse(fixture.organizer.isExpanded)
        fixture.items.menuAction?(.autoHide)
        XCTAssertFalse(settings.autoHide)
        XCTAssertEqual(fixture.items.menuState?.autoHide, false)
    }

    func testArrowClosesArrangementInsteadOfSilentlyIgnoringClick() {
        let fixture = OrganizerFixture()
        fixture.organizer.configure(enabled: true, settings: MenuBarPreferences())
        fixture.items.menuAction?(.arrange)
        XCTAssertTrue(fixture.organizer.isEditingArrangement)
        fixture.organizer.toggle()
        XCTAssertFalse(fixture.organizer.isEditingArrangement)
        XCTAssertFalse(fixture.organizer.isExpanded)
    }

    func testCommandDragDoesNotResizeOrRepairItemsUntilMouseUp() {
        let fixture = OrganizerFixture()
        fixture.organizer.configure(enabled: true, settings: MenuBarPreferences())
        fixture.organizer.toggle()
        let lengths = fixture.items.lengths
        fixture.env.mouseDown = true
        fixture.items.reversed = true
        fixture.organizer.tick()
        XCTAssertEqual(fixture.items.lengths, lengths, "Resizing during Command-drag fights macOS's drag placement")
        XCTAssertFalse(fixture.organizer.isExpanded)
        fixture.env.mouseDown = false
        fixture.organizer.tick()
        XCTAssertTrue(fixture.organizer.isExpanded, "Repair unsafe ordering once the drag finishes")
    }

    func testTemporarilyMissingMenuWindowDoesNotForgetCollapsedState() {
        let fixture = OrganizerFixture()
        fixture.organizer.configure(enabled: true, settings: MenuBarPreferences())
        fixture.organizer.toggle()
        fixture.items.framesAvailable = false
        fixture.organizer.tick()
        XCTAssertFalse(fixture.organizer.isExpanded, "A hidden menu bar or Space transition is not a reversed arrangement")
        fixture.items.framesAvailable = true
        fixture.organizer.tick()
        XCTAssertFalse(fixture.organizer.isExpanded)
        XCTAssertNil(fixture.organizer.issue)
    }

    func testChangingPreferencesDoesNotCollapseAnUnsafePermanentDivider() {
        let fixture = OrganizerFixture()
        var settings = MenuBarPreferences(); settings.permanentlyHiddenSection = true
        fixture.organizer.configure(enabled: true, settings: settings)
        fixture.items.reversed = true
        settings.autoHide = false
        fixture.organizer.configure(enabled: true, settings: settings)
        XCTAssertEqual(fixture.items.lengths[.permanentDivider], 18)
        XCTAssertTrue(fixture.organizer.isExpanded)
    }

    func testToolkitOwnsOrganizerAcrossNavigationDisableAndReenable() {
        let fixture = OrganizerFixture()
        let toolkit = Toolkit(showsUsageStatusItem: false, showsMenuBarOrganizer: true, menuBarOrganizer: fixture.organizer)
        var preferences = Preferences()
        XCTAssertFalse(preferences.featureEnabled(.menuBar))
        toolkit.apply(preferences)
        XCTAssertTrue(fixture.items.active.isEmpty)
        preferences.setFeature(.menuBar, enabled: true)
        var settings = MenuBarPreferences(); settings.permanentlyHiddenSection = true
        preferences.toolkit?.menuBar = settings
        toolkit.apply(preferences)
        XCTAssertEqual(fixture.items.active.count, 3)
        toolkit.select(.feature(.menuBar)); toolkit.select(.settings)
        XCTAssertEqual(fixture.items.active.count, 3, "Collection and menu items must not depend on the settings page being open")
        preferences.setFeature(.menuBar, enabled: false); toolkit.apply(preferences)
        XCTAssertTrue(fixture.items.active.isEmpty)
        preferences.setFeature(.menuBar, enabled: true); toolkit.apply(preferences)
        XCTAssertEqual(fixture.items.active.count, 3)
        toolkit.stop()
        XCTAssertTrue(fixture.items.active.isEmpty)
    }

    func testNativeDividerMarkerStaysAtVisibleTrailingEdgeOfInflatedButton() {
        // Real AppKit autoresizing, with a plain button: no status item or user arrangement.
        let button = NSButton(frame: CGRect(x: 0, y: 0, width: 18, height: 24))
        let marker = OrganizerDividerView(button: button, isDouble: false)
        for width: CGFloat in [5000, 18, 10_000, 18] {
            button.setFrameSize(NSSize(width: width, height: 24))
            XCTAssertEqual(marker.frame.width, 18)
            XCTAssertEqual(marker.frame.maxX, button.bounds.maxX)
        }
        XCTAssertNil(marker.hitTest(NSPoint(x: 9, y: 12)), "The marker must not steal divider clicks or Command-drags")
    }

    func testLifecycleIsIdempotentAndStopReleasesEveryResource() {
        let fixture = OrganizerFixture()
        var settings = MenuBarPreferences()
        settings.hotkey = Hotkey(keyCode: 46, modifiers: 6144)
        settings.permanentlyHiddenSection = true
        fixture.organizer.configure(enabled: true, settings: settings)
        fixture.organizer.configure(enabled: true, settings: settings)
        XCTAssertEqual(fixture.items.created, [.toggle, .divider, .permanentDivider])
        XCTAssertEqual(fixture.keys.registrations, 1)
        fixture.organizer.tick()
        fixture.organizer.stop()
        XCTAssertTrue(fixture.items.active.isEmpty)
        XCTAssertNil(fixture.keys.action)
        XCTAssertFalse(fixture.organizer.isEnabled)
        fixture.time = 1000; fixture.organizer.tick()
        XCTAssertTrue(fixture.items.active.isEmpty, "A late tick must not recreate disabled items")
        fixture.organizer.configure(enabled: true, settings: settings)
        XCTAssertEqual(fixture.items.active.count, 3)
        XCTAssertEqual(fixture.items.created.suffix(3), [.toggle, .divider, .permanentDivider])
        fixture.organizer.stop()
    }

    func testReversedDividerNeverHidesItsRecoveryArrow() {
        let fixture = OrganizerFixture()
        fixture.organizer.configure(enabled: true, settings: MenuBarPreferences())
        fixture.items.reversed = true
        fixture.organizer.toggle()
        XCTAssertTrue(fixture.organizer.isExpanded)
        XCTAssertNotNil(fixture.organizer.issue)
        XCTAssertEqual(fixture.items.lengths[.divider], 18)
        fixture.items.reversed = false
        fixture.organizer.tick()
        fixture.organizer.toggle()
        XCTAssertFalse(fixture.organizer.isExpanded)
        fixture.items.reversed = true
        fixture.time = 2
        fixture.organizer.tick()
        XCTAssertTrue(fixture.organizer.isExpanded, "A later Command-drag must also recover")
        XCTAssertEqual(fixture.items.lengths[.divider], 18)
        fixture.organizer.stop()
    }

    func testPermanentSectionStaysHiddenDuringOrdinaryRevealAndEditingOpensBoth() {
        let fixture = OrganizerFixture()
        var settings = MenuBarPreferences(); settings.permanentlyHiddenSection = true
        fixture.organizer.configure(enabled: true, settings: settings)
        XCTAssertEqual(fixture.items.lengths[.permanentDivider], 18, "Validate restored geometry first")
        fixture.organizer.tick()
        XCTAssertGreaterThan(fixture.items.lengths[.permanentDivider]!, 1000)
        fixture.organizer.toggle(); fixture.organizer.reveal()
        XCTAssertEqual(fixture.items.lengths[.divider], 18)
        XCTAssertGreaterThan(fixture.items.lengths[.permanentDivider]!, 1000)
        fixture.organizer.setEditingArrangement(true)
        XCTAssertEqual(fixture.items.lengths[.permanentDivider], 18)
        fixture.time = 100; fixture.organizer.tick()
        XCTAssertTrue(fixture.organizer.isExpanded)
        fixture.organizer.setEditingArrangement(false)
        XCTAssertGreaterThan(fixture.items.lengths[.permanentDivider]!, 1000)
        fixture.organizer.stop()
    }

    func testAutoHideDefersDuringPointerUseDragAndSettingsThenUsesFullDelay() {
        let fixture = OrganizerFixture()
        var settings = MenuBarPreferences(); settings.autoHideSeconds = 5
        fixture.organizer.configure(enabled: true, settings: settings)
        fixture.time = 6; fixture.env.pointerInMenuBar = true; fixture.organizer.tick()
        XCTAssertTrue(fixture.organizer.isExpanded)
        fixture.env.pointerInMenuBar = false; fixture.env.mouseDown = true
        fixture.time = 12; fixture.organizer.tick()
        XCTAssertTrue(fixture.organizer.isExpanded)
        fixture.env.mouseDown = false; fixture.organizer.setSettingsVisible(true)
        fixture.time = 20; fixture.organizer.tick()
        XCTAssertTrue(fixture.organizer.isExpanded)
        fixture.organizer.setSettingsVisible(false)
        fixture.time = 24; fixture.organizer.tick()
        XCTAssertTrue(fixture.organizer.isExpanded)
        fixture.time = 25; fixture.organizer.tick()
        XCTAssertFalse(fixture.organizer.isExpanded)
        fixture.organizer.stop()
    }

    func testScreenResizeUpdatesCollapsedLengthAndNotchOcclusionRecovers() {
        let fixture = OrganizerFixture()
        fixture.organizer.configure(enabled: true, settings: MenuBarPreferences())
        fixture.organizer.toggle()
        XCTAssertEqual(fixture.items.lengths[.divider], 2880)
        fixture.env.screens.append(OrganizerScreen(frame: CGRect(x: -4000, y: 0, width: 4000, height: 2000), menuRegions: []))
        fixture.organizer.tick()
        XCTAssertFalse(fixture.organizer.isExpanded)
        XCTAssertEqual(fixture.items.lengths[.divider], 8000)
        fixture.env.screens[0].menuRegions = [CGRect(x: 0, y: 876, width: 1100, height: 24), CGRect(x: 1350, y: 876, width: 90, height: 24)]
        fixture.time = 2
        fixture.organizer.tick()
        XCTAssertTrue(fixture.organizer.isExpanded)
        XCTAssertNotNil(fixture.organizer.issue)
        XCTAssertEqual(fixture.items.lengths[.divider], 18)
        fixture.organizer.stop()
    }

    func testExternalHiddenBarAndUnsupportedOSNeverInstallOrRegister() {
        let fixture = OrganizerFixture()
        fixture.env.competingOrganizer = true
        var settings = MenuBarPreferences(); settings.hotkey = Hotkey(keyCode: 46, modifiers: 6144)
        fixture.organizer.configure(enabled: true, settings: settings)
        XCTAssertTrue(fixture.items.created.isEmpty)
        XCTAssertEqual(fixture.keys.registrations, 0)
        XCTAssertTrue(fixture.organizer.isEnabled, "Keep the requested state so Retry works")
        fixture.env.competingOrganizer = false
        fixture.organizer.configure(enabled: true, settings: settings)
        XCTAssertTrue(fixture.organizer.isInstalled)
        fixture.env.supportsLengthTechnique = false; fixture.organizer.tick()
        XCTAssertTrue(fixture.items.active.isEmpty)
        XCTAssertNil(fixture.keys.action)
        XCTAssertNotNil(fixture.organizer.issue)
        fixture.organizer.stop()
    }

    func testHotkeySuspendConflictAndDefaultOptIn() {
        let fixture = OrganizerFixture()
        var settings = MenuBarPreferences()
        fixture.organizer.configure(enabled: true, settings: settings)
        XCTAssertEqual(fixture.keys.registrations, 0)
        settings.hotkey = Hotkey(keyCode: 46, modifiers: 6144)
        fixture.keys.error = "Already registered"
        fixture.organizer.configure(enabled: true, settings: settings)
        XCTAssertEqual(fixture.organizer.hotkeyError, "Already registered")
        fixture.keys.error = nil
        fixture.organizer.configure(enabled: true, settings: settings)
        XCTAssertNil(fixture.organizer.hotkeyError)
        fixture.keys.action?()
        XCTAssertFalse(fixture.organizer.isExpanded)
        fixture.organizer.setShortcutRecording(true)
        XCTAssertNil(fixture.keys.action)
        fixture.organizer.setShortcutRecording(false)
        XCTAssertNotNil(fixture.keys.action)
        fixture.organizer.stop()
    }

    func testHoverRequiresDwellAndLengthIsBounded() {
        let fixture = OrganizerFixture()
        var settings = MenuBarPreferences(); settings.hoverToReveal = true; settings.startCollapsed = true
        fixture.organizer.configure(enabled: true, settings: settings)
        fixture.organizer.tick()
        XCTAssertFalse(fixture.organizer.isExpanded)
        fixture.env.pointerInMenuBar = true; fixture.organizer.tick()
        fixture.time = 0.4; fixture.organizer.tick()
        XCTAssertFalse(fixture.organizer.isExpanded)
        fixture.time = 0.5; fixture.organizer.tick()
        XCTAssertTrue(fixture.organizer.isExpanded)
        fixture.env.screens[0].frame.size.width = 9000
        XCTAssertEqual(fixture.env.collapsedLength, 10_000)
        fixture.organizer.stop()
    }
}

@MainActor private final class OrganizerFixture {
    let items = FixtureOrganizerItems()
    let keys = FixtureOrganizerHotkey()
    var time: TimeInterval = 0
    var env = OrganizerEnvironment(screens: [OrganizerScreen(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        menuRegions: [CGRect(x: 0, y: 876, width: 1440, height: 24)])])
    lazy var organizer = MenuBarOrganizer(statusItems: items, hotkeys: keys, automaticTicks: false,
        environment: { [unowned self] in self.env }, now: { [unowned self] in self.time })
}

@MainActor private final class FixtureOrganizerItems: OrganizerStatusItems {
    var created: [OrganizerItem] = []
    var active = Set<OrganizerItem>()
    var lengths: [OrganizerItem: CGFloat] = [:]
    var reversed = false
    var framesAvailable = true
    var delaysLayout = false
    private var pendingOrigins: [OrganizerItem: CGFloat] = [:]
    func settleLayout() { pendingOrigins.removeAll() }
    var menuState: OrganizerMenuState?
    var menuAction: ((OrganizerMenuAction) -> Void)?
    func updateMenu(_ state: OrganizerMenuState, action: @escaping (OrganizerMenuAction) -> Void) {
        menuState = state; menuAction = action
    }
    func install(_ item: OrganizerItem, action: @escaping () -> Void, settings: @escaping () -> Void) {
        created.append(item); active.insert(item)
    }
    func remove(_ item: OrganizerItem) { active.remove(item); lengths[item] = nil }
    func setLength(_ length: CGFloat, for item: OrganizerItem) {
        if delaysLayout, lengths[item] != length, let old = frame(of: item) { pendingOrigins[item] = old.minX }
        lengths[item] = length
    }
    func setExpanded(_ expanded: Bool) {}
    func frame(of item: OrganizerItem) -> CGRect? {
        guard framesAvailable, active.contains(item) else { return nil }
        let width = lengths[item] ?? 18
        let right: CGFloat
        switch item {
        case .toggle: right = reversed ? 900 : 1300
        case .divider: right = 1276
        case .permanentDivider: right = 1276 - (lengths[.divider] ?? 18) - 100
        }
        return CGRect(x: pendingOrigins[item] ?? right - width, y: 876, width: width, height: 24)
    }
}

@MainActor private final class FixtureOrganizerHotkey: OrganizerHotkey {
    var registrations = 0
    var action: (() -> Void)?
    var error: String?
    func register(_ hotkey: Hotkey, action: @escaping () -> Void) -> String? {
        registrations += 1
        if error == nil { self.action = action }
        return error
    }
    func unregister() { action = nil }
}
