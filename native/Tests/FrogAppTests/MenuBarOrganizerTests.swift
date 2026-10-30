import AppKit
import SwiftUI
import XCTest
import FrogCore
@testable import FrogApp

@MainActor final class MenuBarOrganizerTests: XCTestCase {
    func testMenuBarTallerThanTheStatusBarThicknessIsStillTheMenuBar() {
        // An external display on macOS 26: a 30-point menu bar, no notch, status-bar thickness 22.
        let screen = OrganizerScreen(frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
                                     visibleFrame: CGRect(x: 0, y: 0, width: 2560, height: 1410),
                                     safeAreaTop: 0, thickness: 22, notchSides: nil)
        XCTAssertEqual(screen.menuRegions, [CGRect(x: 0, y: 1410, width: 2560, height: 30)])
        XCTAssertTrue(screen.menuBarContains(CGPoint(x: 1200, y: 1412), thickness: 22), "The lower edge of the bar is still the bar")
        XCTAssertFalse(screen.menuBarContains(CGPoint(x: 1200, y: 1400), thickness: 22))
        let hidden = OrganizerScreen(frame: screen.frame, visibleFrame: screen.frame, safeAreaTop: 0, thickness: 22, notchSides: nil)
        XCTAssertEqual(hidden.menuRegions, [CGRect(x: 0, y: 1418, width: 2560, height: 22)], "An auto-hidden bar reserves no space")
        let notch = (CGRect(x: 0, y: 944, width: 650, height: 38), CGRect(x: 862, y: 944, width: 650, height: 38))
        let builtIn = OrganizerScreen(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                      visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
                                      safeAreaTop: 38, thickness: 22, notchSides: notch)
        XCTAssertEqual(builtIn.menuRegions, [notch.0, notch.1])
    }

    func testCollapsesWhenStatusItemWindowsAreTallerThanTheKnownMenuBand() {
        let fixture = OrganizerFixture()
        // The windows fill the 30-point bar even where only the 22-point thickness is known.
        fixture.env = OrganizerEnvironment(screens: [OrganizerScreen(frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            menuRegions: [CGRect(x: 0, y: 1418, width: 2560, height: 22)])])
        fixture.items.bar = (1410, 30)
        var settings = MenuBarPreferences(); settings.autoHideSeconds = 5
        fixture.organizer.configure(enabled: true, settings: settings)
        fixture.organizer.tick()
        XCTAssertNil(fixture.organizer.issue)
        fixture.time = 5; fixture.organizer.tick()
        XCTAssertFalse(fixture.organizer.isExpanded, "Auto-hide must work on a display without a notch")
        XCTAssertEqual(fixture.items.lengths[.divider], 5120)
        fixture.organizer.toggle(); fixture.organizer.toggle()
        XCTAssertFalse(fixture.organizer.isExpanded)
        fixture.items.bar = (1440, 30)
        fixture.time = 10; fixture.organizer.tick()
        XCTAssertTrue(fixture.organizer.isExpanded, "An arrow above the screen is still unsafe")
        fixture.organizer.stop()
    }

    func testHelpersStayNarrowWhereTheSystemPadsEveryStatusItem() {
        let fixture = OrganizerFixture()
        var settings = MenuBarPreferences(); settings.permanentlyHiddenSection = true
        fixture.organizer.configure(enabled: true, settings: settings)
        XCTAssertEqual(fixture.items.lengths, [.toggle: 24, .divider: 18, .permanentDivider: 18])
        fixture.organizer.stop()
        // macOS 26 adds 8 points on each side of every item.
        fixture.env.statusItemPadding = 16; fixture.items.padding = 16
        fixture.organizer.configure(enabled: true, settings: settings)
        XCTAssertEqual(fixture.items.lengths, [.toggle: 12, .divider: 8, .permanentDivider: 8])
        fixture.organizer.tick()
        XCTAssertNil(fixture.organizer.issue)
        fixture.organizer.toggle()
        XCTAssertFalse(fixture.organizer.isExpanded)
        XCTAssertEqual(fixture.items.lengths[.toggle], 12)
        XCTAssertEqual(fixture.items.lengths[.divider], 2880)
        fixture.organizer.reveal()
        XCTAssertEqual(fixture.items.lengths[.divider], 8)
        fixture.organizer.stop()
    }

    func testNarrowDividerMarkerDrawsInsideItsButton() {
        let button = NSButton(frame: CGRect(x: 0, y: 0, width: 8, height: 22))
        let single = OrganizerDividerView(button: button, isDouble: false, width: 8)
        XCTAssertEqual(single.frame, CGRect(x: 0, y: 0, width: 8, height: 22))
        XCTAssertEqual(single.lineOrigins, [4])
        XCTAssertEqual(OrganizerDividerView(button: button, isDouble: true, width: 8).lineOrigins, [2, 6])
        XCTAssertEqual(OrganizerDividerView(button: NSButton(frame: CGRect(x: 0, y: 0, width: 18, height: 22)), isDouble: true).lineOrigins, [7, 11])
    }

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

    func testStartCollapsedHidesBothSectionsWhileTheSecondDividerWouldStillBeMoving() {
        let fixture = OrganizerFixture()
        var settings = MenuBarPreferences()
        settings.permanentlyHiddenSection = true; settings.startCollapsed = true; settings.autoHide = false
        fixture.organizer.configure(enabled: true, settings: settings)
        XCTAssertEqual(fixture.items.lengths[.permanentDivider], 18, "Validate restored geometry first")
        fixture.items.delaysLayout = true
        fixture.organizer.tick()
        XCTAssertFalse(fixture.organizer.isExpanded, "Resizing the second divider first must not make the order look reversed")
        XCTAssertEqual(fixture.items.lengths[.divider], 2880)
        XCTAssertEqual(fixture.items.lengths[.permanentDivider], 2880)
        fixture.time = 0.5; fixture.organizer.tick()
        fixture.items.settleLayout()
        fixture.time = 2; fixture.organizer.tick()
        XCTAssertFalse(fixture.organizer.isExpanded)
        XCTAssertNil(fixture.organizer.issue)
        fixture.organizer.stop()
    }

    func testArrowEndsArrangingAndHidesWhileTheSecondDividerWouldStillBeMoving() {
        let fixture = OrganizerFixture()
        var settings = MenuBarPreferences(); settings.permanentlyHiddenSection = true
        fixture.organizer.configure(enabled: true, settings: settings)
        fixture.organizer.tick()
        fixture.time = 5; fixture.organizer.setEditingArrangement(true)
        XCTAssertEqual(fixture.items.lengths[.permanentDivider], 18)
        fixture.time = 10; fixture.items.delaysLayout = true
        fixture.organizer.toggle()
        XCTAssertFalse(fixture.organizer.isEditingArrangement)
        XCTAssertFalse(fixture.organizer.isExpanded, "The click hides, as it does without a second divider")
        XCTAssertEqual(fixture.items.lengths[.divider], 2880)
        XCTAssertEqual(fixture.items.lengths[.permanentDivider], 2880)
        XCTAssertEqual(fixture.items.menuState, OrganizerMenuState(expanded: false, arranging: false, autoHide: true))
        fixture.items.settleLayout(); fixture.items.delaysLayout = false
        fixture.time = 12; fixture.organizer.tick()
        XCTAssertFalse(fixture.organizer.isExpanded)
        XCTAssertNil(fixture.organizer.issue)

        // A wrong order keeps arranging on and says why, as before.
        fixture.organizer.setEditingArrangement(true)
        fixture.time = 20; fixture.items.reversed = true
        fixture.organizer.toggle()
        XCTAssertTrue(fixture.organizer.isEditingArrangement)
        XCTAssertTrue(fixture.organizer.isExpanded)
        XCTAssertNotNil(fixture.organizer.issue)
        // A held mouse button keeps the icons shown; arranging still ends.
        fixture.items.reversed = false; fixture.env.mouseDown = true
        fixture.organizer.toggle()
        XCTAssertFalse(fixture.organizer.isEditingArrangement)
        XCTAssertTrue(fixture.organizer.isExpanded)
        XCTAssertNil(fixture.organizer.issue)
        XCTAssertEqual(fixture.items.lengths[.divider], 18)
        XCTAssertEqual(fixture.items.lengths[.permanentDivider], 2880)
        fixture.organizer.stop()
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
        var openedSettings = false
        adapter.setMenuAction { action in
            if case .autoHide = action { changedAutoHide = true }
            if case .settings = action { openedSettings = true }
        }
        adapter.updateMenu(OrganizerMenuState(expanded: false, arranging: false, autoHide: true))
        XCTAssertFalse(adapter.contextMenu.items.contains(where: \.isSeparatorItem), "Frog's menus have no lines")
        XCTAssertEqual(adapter.contextMenu.items.map(\.title),
                       ["Show hidden icons", "Show all & arrange…", "Automatically hide icons", "Hidden bar settings…"])
        let autoHide = try XCTUnwrap(adapter.contextMenu.items.first { $0.title == "Automatically hide icons" })
        XCTAssertEqual(autoHide.state, .on)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(autoHide.action), to: autoHide.target, from: autoHide))
        XCTAssertTrue(changedAutoHide)
        let settings = try XCTUnwrap(adapter.contextMenu.items.first { $0.title == "Hidden bar settings…" })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(settings.action), to: settings.target, from: settings))
        XCTAssertTrue(openedSettings, "The settings item reports through the same action as the others")
        adapter.updateMenu(OrganizerMenuState(expanded: true, arranging: true, autoHide: false))
        XCTAssertEqual(adapter.contextMenu.items[0].title, "Hide menu bar icons")
        XCTAssertEqual(adapter.contextMenu.items[1].title, "Done arranging")
        XCTAssertEqual(adapter.contextMenu.items[2].title, "Automatically hide icons")
        XCTAssertEqual(adapter.contextMenu.items[2].state, .off)
        XCTAssertTrue(NativeOrganizerStatusItems.arrowImage(expanded: true).isTemplate)
    }

    func testNativeContextMenuStartsWithTheReasonWhileAProblemKeepsTheIconsShown() throws {
        _ = NSApplication.shared
        let fixture = OrganizerFixture()
        fixture.organizer.configure(enabled: true, settings: MenuBarPreferences())
        fixture.items.reversed = true; fixture.organizer.tick()
        let issue = try XCTUnwrap(fixture.organizer.issue)
        fixture.organizer.stop()
        let adapter = NativeOrganizerStatusItems()
        adapter.updateMenu(OrganizerMenuState(expanded: true, arranging: false, autoHide: true, issue: issue))
        // A menu does not wrap, so each sentence gets its own line.
        let reason = Array(adapter.contextMenu.items.prefix { !$0.isEnabled })
        XCTAssertEqual(reason.map(\.title), ["Command-drag Frog's divider to the LEFT of its arrow.",
                                             "Frog keeps everything revealed until the arrow is safely on the right."])
        XCTAssertEqual(reason.map(\.title).joined(separator: " "), issue)
        XCTAssertTrue(reason.allSatisfy { $0.action == nil && !$0.isEnabled }, "The reason is read, not chosen")
        XCTAssertEqual(adapter.contextMenu.items.dropFirst(reason.count).map(\.title),
                       ["Hide menu bar icons", "Show all & arrange…", "Automatically hide icons", "Hidden bar settings…"])
        XCTAssertEqual(NativeOrganizerStatusItems.arrowToolTip(expanded: true, issue: issue), issue, "Resting on the arrow says it too")
        XCTAssertEqual(NativeOrganizerStatusItems.arrowToolTip(expanded: true, issue: nil),
                       "Hide menu bar icons. Right-click for options; Option-click to arrange all icons.")
        XCTAssertEqual(NativeOrganizerStatusItems.arrowToolTip(expanded: false, issue: nil),
                       "Show hidden icons. Right-click for options; Option-click to arrange all icons.")
        adapter.updateMenu(OrganizerMenuState(expanded: true, arranging: false, autoHide: true))
        XCTAssertEqual(adapter.contextMenu.items[0].title, "Hide menu bar icons", "The reason leaves with the problem")
    }

    func testArrowAndShortcutLeadToTheReasonWhenAProblemKeepsTheIconsShown() {
        let fixture = OrganizerFixture()
        var opened = 0
        fixture.organizer.onShowSettings = { opened += 1 }
        var settings = MenuBarPreferences()
        settings.hotkey = Hotkey(keyCode: 46, modifiers: 6144); settings.permanentlyHiddenSection = true
        fixture.organizer.configure(enabled: true, settings: settings)
        fixture.organizer.tick()
        XCTAssertNil(fixture.items.menuState?.issue)
        fixture.time = 5; fixture.items.reversed = true
        fixture.organizer.toggle()
        XCTAssertTrue(fixture.organizer.isExpanded)
        XCTAssertNotNil(fixture.organizer.issue)
        XCTAssertEqual(opened, 1, "A click that cannot hide the icons opens the page that says why")
        XCTAssertEqual(fixture.items.menuState?.issue, fixture.organizer.issue, "The arrow's menu has the reason before the timer comes round")
        fixture.organizer.toggle()
        XCTAssertEqual(opened, 2, "The shortcut ends in the same place")
        fixture.time = 60; fixture.organizer.tick()
        XCTAssertEqual(opened, 2, "Auto-hide that cannot hide opens nothing")
        XCTAssertEqual(fixture.items.menuState?.issue, fixture.organizer.issue)

        fixture.items.reversed = false; fixture.organizer.tick()
        XCTAssertNil(fixture.items.menuState?.issue)
        fixture.time = 62; fixture.organizer.toggle()
        XCTAssertFalse(fixture.organizer.isExpanded)
        fixture.organizer.toggle()
        XCTAssertTrue(fixture.organizer.isExpanded)
        XCTAssertEqual(opened, 2, "Hiding and showing that work open nothing")

        fixture.time = 70; fixture.organizer.setEditingArrangement(true)
        fixture.items.reversed = true
        fixture.organizer.toggle()
        XCTAssertEqual(opened, 2, "A spacer that may still be moving is not yet a problem to explain")
        fixture.time = 72; fixture.organizer.toggle()
        XCTAssertTrue(fixture.organizer.isEditingArrangement)
        XCTAssertEqual(opened, 3, "Nor is a click silent while arranging")
        XCTAssertEqual(fixture.items.menuState, OrganizerMenuState(expanded: true, arranging: true, autoHide: true, issue: fixture.organizer.issue))
        fixture.organizer.stop()
    }

    func testHideAskedForWhileTheMenuBarGivesNoFramesHappensOnceTheyAreBack() {
        let fixture = OrganizerFixture()
        var opened = 0
        fixture.organizer.onShowSettings = { opened += 1 }
        var settings = MenuBarPreferences(); settings.hotkey = Hotkey(keyCode: 46, modifiers: 6144)
        fixture.organizer.configure(enabled: true, settings: settings)
        fixture.organizer.tick()
        fixture.items.framesAvailable = false
        fixture.organizer.toggle()
        XCTAssertTrue(fixture.organizer.isExpanded)
        XCTAssertNil(fixture.organizer.issue)
        XCTAssertEqual(opened, 0, "A bar that is only out of sight is nothing to explain")
        fixture.organizer.tick()
        XCTAssertTrue(fixture.organizer.isExpanded)
        fixture.items.framesAvailable = true
        fixture.organizer.tick()
        XCTAssertFalse(fixture.organizer.isExpanded, "The request is kept until the bar can be judged")
        fixture.organizer.tick()
        fixture.organizer.toggle()
        XCTAssertTrue(fixture.organizer.isExpanded)

        fixture.items.framesAvailable = false
        fixture.organizer.toggle()
        fixture.organizer.setEditingArrangement(true)
        fixture.items.framesAvailable = true
        fixture.organizer.tick()
        XCTAssertTrue(fixture.organizer.isExpanded, "Asking for everything afterwards takes the request back")

        // An open settings page holds back only the hide at start, not one that was asked for.
        fixture.organizer.setEditingArrangement(false)
        fixture.organizer.setSettingsVisible(true)
        fixture.items.framesAvailable = false
        fixture.organizer.toggle()
        fixture.items.framesAvailable = true
        fixture.organizer.tick()
        XCTAssertFalse(fixture.organizer.isExpanded, "The shortcut hides while the settings page is open")
        fixture.organizer.stop()
        settings.startCollapsed = true
        fixture.organizer.configure(enabled: true, settings: settings)
        fixture.organizer.tick()
        XCTAssertTrue(fixture.organizer.isExpanded, "Switching the organizer on from its settings page does not hide at once")
        fixture.organizer.stop()
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

    func testOneMenuActionServesTheOrganizerForItsWholeLife() {
        let fixture = OrganizerFixture()
        var opened = 0
        fixture.organizer.onShowSettings = { opened += 1 }
        fixture.organizer.configure(enabled: true, settings: MenuBarPreferences())
        for time in [1.0, 2, 3] { fixture.time = time; fixture.organizer.tick() }
        fixture.organizer.configure(enabled: false, settings: MenuBarPreferences())
        fixture.organizer.configure(enabled: true, settings: MenuBarPreferences())
        fixture.time = 4; fixture.organizer.tick()
        XCTAssertEqual(fixture.items.menuActionsSet, 1, "Neither a tick nor a restart hands over a new one")
        fixture.items.menuAction?(.settings)
        XCTAssertEqual(opened, 1)
        fixture.items.menuAction?(.toggle)
        XCTAssertFalse(fixture.organizer.isExpanded, "The arrow reports its click through it too")
        fixture.organizer.stop()
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

    func testThePluginOwnsTheOrganizerFromStartToStop() async throws {
        let fixture = OrganizerFixture()
        HiddenBarPlugin.makeOrganizer = { fixture.organizer }
        defer { HiddenBarPlugin.makeOrganizer = nil }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var configuration = Configuration()
        var legacy = MenuBarPreferences(); legacy.permanentlyHiddenSection = true; legacy.autoHideSeconds = 30
        configuration.preferences.ensureToolkit()
        configuration.preferences.toolkit?.menuBar = legacy
        try ConfigurationStore(directory: directory).save(configuration)
        let model = AppModel(dataDirectory: directory, registerShortcuts: false, readKey: { _ in nil })
        defer { model.shutdown() }
        await model.pluginHost.syncAndWait()
        XCTAssertTrue(fixture.items.active.isEmpty, "Off by default")

        try await model.setFeature(.menuBar, enabled: true)
        await model.pluginHost.syncAndWait()
        let plugin = try XCTUnwrap(model.pluginHost.running["hidden-bar"] as? HiddenBarPlugin)
        XCTAssertEqual(fixture.items.active.count, 3, "Seeded from the old preferences: the always-hidden section is on")
        XCTAssertEqual(plugin.settings.autoHideSeconds, 30)
        let text = try String(contentsOf: model.settingsFile.fileURL, encoding: .utf8)
        XCTAssertTrue(text.contains("[hidden-bar]") && text.contains("always-hidden-section = true"), text)

        let hide = try await model.pluginHost.run("hidden-bar.hide", ActionInput(source: .agent))
        XCTAssertFalse(fixture.organizer.isExpanded)
        XCTAssertTrue(hide.json.contains("\"hidden\" : true"), hide.json)
        _ = try await model.pluginHost.run("hidden-bar.show", ActionInput(source: .agent))
        XCTAssertTrue(fixture.organizer.isExpanded)
        fixture.time = 5
        _ = try await model.pluginHost.run("hidden-bar.toggle", ActionInput(source: .agent))
        XCTAssertFalse(fixture.organizer.isExpanded)

        plugin.update { $0.alwaysHiddenSection = false }
        XCTAssertEqual(fixture.items.active.count, 2)
        XCTAssertFalse(try model.settingsFile.section("hidden-bar", as: HiddenBarSettings.self).value.alwaysHiddenSection)

        try await model.setFeature(.menuBar, enabled: false)
        await model.pluginHost.syncAndWait()
        XCTAssertTrue(fixture.items.active.isEmpty)
        XCTAssertNil(model.pluginHost.running["hidden-bar"])
        do {
            _ = try await model.pluginHost.run("hidden-bar.toggle", ActionInput(source: .agent))
            XCTFail("The plugin is off")
        } catch ActionError.pluginOff {}
    }

    func testTheShortcutGoesThroughTheSharedHotkeys() async throws {
        let fixture = OrganizerFixture()
        HiddenBarPlugin.makeOrganizer = { fixture.organizer }
        defer { HiddenBarPlugin.makeOrganizer = nil }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var configuration = Configuration()
        configuration.preferences.setFeature(.menuBar, enabled: true)
        try ConfigurationStore(directory: directory).save(configuration)
        let model = AppModel(dataDirectory: directory, registerShortcuts: false, readKey: { _ in nil })
        defer { model.shutdown() }
        await model.pluginHost.syncAndWait()
        let plugin = try XCTUnwrap(model.pluginHost.running["hidden-bar"] as? HiddenBarPlugin)
        let hotkey = Hotkey(keyCode: 11, modifiers: 6144)
        plugin.update { $0.shortcut = try? Shortcut(hotkey) }
        XCTAssertNil(plugin.shortcutError)
        XCTAssertEqual(model.pluginShortcuts[AppModel.menuBarID]?.hotkey, hotkey)
        fixture.organizer.tick()
        XCTAssertTrue(fixture.organizer.isExpanded)
        model.pluginShortcuts[AppModel.menuBarID]?.action()
        XCTAssertFalse(fixture.organizer.isExpanded)
        try await model.setFeature(.menuBar, enabled: false)
        await model.pluginHost.syncAndWait()
        XCTAssertNil(model.pluginShortcuts[AppModel.menuBarID], "Stopping gives the shortcut back")
    }

    /// `menuBar-arrow-*.png`: the page with its arrow in the bar, the icons hidden and a shortcut.
    func testPageShotWithTheArrowInstalled() async throws {
        guard ProcessInfo.processInfo.environment["FROG_PAGE_SHOTS"] != nil else { throw XCTSkip("Set FROG_PAGE_SHOTS") }
        let fixture = OrganizerFixture()
        HiddenBarPlugin.makeOrganizer = { fixture.organizer }
        defer { HiddenBarPlugin.makeOrganizer = nil }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var configuration = Configuration()
        configuration.preferences.setFeature(.menuBar, enabled: true)
        try ConfigurationStore(directory: directory).save(configuration)
        let model = AppModel(dataDirectory: directory, registerShortcuts: false, readKey: { _ in nil })
        defer { model.shutdown() }
        await model.pluginHost.syncAndWait()
        let plugin = try XCTUnwrap(model.pluginHost.running["hidden-bar"] as? HiddenBarPlugin)
        plugin.update { $0.shortcut = try? Shortcut(Hotkey(keyCode: 11, modifiers: 6144)); $0.alwaysHiddenSection = true }
        fixture.organizer.tick()
        fixture.organizer.hide()
        try await savePluginPageShot("menuBar-arrow", model: model) { plugin.page()! }
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
        fixture.organizer.tick()
        fixture.organizer.stop()
        XCTAssertTrue(fixture.items.active.isEmpty)
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

    func testArrangementProblemShowsTheAlwaysHiddenSectionOnlyWhileItLasts() {
        let fixture = OrganizerFixture()
        var settings = MenuBarPreferences(); settings.permanentlyHiddenSection = true; settings.autoHideSeconds = 5
        fixture.organizer.configure(enabled: true, settings: settings)
        fixture.organizer.tick()
        XCTAssertGreaterThan(fixture.items.lengths[.permanentDivider]!, 1000)
        fixture.items.reversed = true
        fixture.time = 2; fixture.organizer.tick()
        XCTAssertNotNil(fixture.organizer.issue)
        XCTAssertEqual(fixture.items.lengths[.permanentDivider], 18, "Everything is shown while the arrow is unsafe")
        XCTAssertFalse(fixture.organizer.isEditingArrangement, "Nobody asked to arrange")
        fixture.items.reversed = false
        fixture.time = 3; fixture.organizer.tick()
        XCTAssertNil(fixture.organizer.issue)
        XCTAssertFalse(fixture.organizer.isEditingArrangement)
        XCTAssertGreaterThan(fixture.items.lengths[.permanentDivider]!, 1000, "The always-hidden section hides again once the order is right")
        XCTAssertTrue(fixture.organizer.isExpanded)
        fixture.time = 6.9; fixture.organizer.tick()
        XCTAssertTrue(fixture.organizer.isExpanded)
        fixture.time = 7; fixture.organizer.tick()
        XCTAssertFalse(fixture.organizer.isExpanded, "Auto-hide counts from the last moment the problem was seen")
        XCTAssertEqual(fixture.items.lengths[.divider], 2880)

        // Arranging that was asked for is not ended by a problem that comes and goes.
        fixture.organizer.setEditingArrangement(true)
        fixture.items.reversed = true
        fixture.time = 10; fixture.organizer.tick()
        fixture.items.reversed = false
        fixture.time = 11; fixture.organizer.tick()
        XCTAssertNil(fixture.organizer.issue)
        XCTAssertTrue(fixture.organizer.isEditingArrangement)
        XCTAssertEqual(fixture.items.lengths[.permanentDivider], 18)
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

    /// The settings page says "not showing" when it is put into its window, before it says anything else.
    func testSettingsReportedHiddenTwiceEndNoArrangementStartedFromTheArrow() {
        let fixture = OrganizerFixture()
        fixture.organizer.configure(enabled: true, settings: MenuBarPreferences())
        fixture.items.menuAction?(.arrange)
        fixture.organizer.setSettingsVisible(false)
        XCTAssertTrue(fixture.organizer.isEditingArrangement, "Opening Settings must not end arranging")
        fixture.organizer.setSettingsVisible(true); fixture.organizer.setSettingsVisible(true)
        XCTAssertTrue(fixture.organizer.isEditingArrangement)
        fixture.organizer.setSettingsVisible(false)
        XCTAssertFalse(fixture.organizer.isEditingArrangement, "Leaving the page that was showing still ends arranging")
        fixture.organizer.stop()
    }

    /// A closed settings window keeps its page. Only a page that can be seen may hold the hidden icons open.
    func testSettingsPageInAWindowThatIsNotOnScreenLeavesAutoHideAlone() async throws {
        // The page keeps its organizer for as long as SwiftUI keeps the page, so this one owns what it reads.
        final class Clock { var time: TimeInterval = 0 }
        let clock = Clock()
        let env = OrganizerFixture().env
        let organizer = MenuBarOrganizer(statusItems: FixtureOrganizerItems(), automaticTicks: false,
                                         environment: { env }, now: { clock.time })
        var settings = MenuBarPreferences(); settings.autoHideSeconds = 5
        organizer.configure(enabled: true, settings: settings)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        HiddenBarPlugin.makeOrganizer = { organizer }
        defer { HiddenBarPlugin.makeOrganizer = nil }
        var configuration = Configuration()
        configuration.preferences.setFeature(.menuBar, enabled: true)
        try ConfigurationStore(directory: directory).save(configuration)
        let model = AppModel(dataDirectory: directory, registerShortcuts: false, readKey: { _ in nil })
        defer { model.shutdown() }
        await model.pluginHost.syncAndWait()
        let plugin = try XCTUnwrap(model.pluginHost.running["hidden-bar"] as? HiddenBarPlugin)
        plugin.update { $0.autoHideSeconds = 5 }
        let host = NSHostingView(rootView: HiddenBarPage(plugin: plugin).environmentObject(model))
        // The window is never shown: it holds the page the way a closed settings window does.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        // What the page reports arrives on the main queue.
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(organizer.isExpanded)
        clock.time = 6; organizer.tick()
        XCTAssertFalse(organizer.isExpanded, "A page nobody can see must not keep the icons from hiding")
        organizer.stop()
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
        XCTAssertTrue(fixture.organizer.isEnabled, "Keep the requested state so Retry works")
        fixture.env.competingOrganizer = false
        fixture.organizer.configure(enabled: true, settings: settings)
        XCTAssertTrue(fixture.organizer.isInstalled)
        fixture.env.supportsLengthTechnique = false; fixture.organizer.tick()
        XCTAssertTrue(fixture.items.active.isEmpty)
        XCTAssertNotNil(fixture.organizer.issue)
        fixture.organizer.stop()
    }

    func testOrganizerStartsByItselfOnceHiddenBarQuits() {
        let fixture = OrganizerFixture()
        fixture.env.competingOrganizer = true
        var settings = MenuBarPreferences(); settings.hotkey = Hotkey(keyCode: 46, modifiers: 6144)
        fixture.organizer.configure(enabled: true, settings: settings)
        XCTAssertFalse(fixture.organizer.isInstalled)
        // Some other application quits while Hidden Bar is still running.
        fixture.applications.changed?()
        XCTAssertTrue(fixture.items.created.isEmpty)
        XCTAssertNotNil(fixture.organizer.issue)
        fixture.env.competingOrganizer = false
        fixture.applications.changed?()
        XCTAssertTrue(fixture.organizer.isInstalled, "No timer runs while the helpers are removed, so the quit itself has to restart the organizer")
        XCTAssertNil(fixture.organizer.issue)
        XCTAssertEqual(fixture.items.created, [.toggle, .divider])
        XCTAssertNil(fixture.applications.changed, "Nothing is left to wait for")
        // Hidden Bar starts while Frog's helpers are installed, and quits again.
        fixture.env.competingOrganizer = true; fixture.organizer.tick()
        XCTAssertTrue(fixture.items.active.isEmpty)
        fixture.env.competingOrganizer = false
        fixture.applications.changed?()
        XCTAssertEqual(fixture.items.active, [.toggle, .divider])
        fixture.organizer.stop()
    }

    func testOrganizerSwitchedOffNeverStartsWhenHiddenBarQuits() {
        let fixture = OrganizerFixture()
        fixture.env.competingOrganizer = true
        fixture.organizer.configure(enabled: true, settings: MenuBarPreferences())
        let late = fixture.applications.changed
        XCTAssertNotNil(late)
        fixture.organizer.stop()
        XCTAssertNil(fixture.applications.changed, "Switching the feature off ends the wait")
        fixture.env.competingOrganizer = false
        late?()
        XCTAssertTrue(fixture.items.created.isEmpty, "A change that was already on its way must not install helpers")
        XCTAssertFalse(fixture.organizer.isEnabled)
        // An unsupported macOS has nothing to wait for.
        fixture.env.supportsLengthTechnique = false
        fixture.organizer.configure(enabled: true, settings: MenuBarPreferences())
        XCTAssertNotNil(fixture.organizer.issue)
        XCTAssertNil(fixture.applications.changed)
        fixture.organizer.stop()
    }

    func testFrogMenuCarriesTheReasonOnlyWhileTheArrowIsGone() {
        let fixture = OrganizerFixture()
        fixture.organizer.configure(enabled: true, settings: MenuBarPreferences())
        XCTAssertNil(fixture.organizer.menuNotice)
        // A reversed arrangement keeps the arrow on screen, and the arrow's own menu leads to the reason.
        fixture.items.reversed = true; fixture.organizer.tick()
        XCTAssertNotNil(fixture.organizer.issue)
        XCTAssertNil(fixture.organizer.menuNotice)
        fixture.items.reversed = false
        fixture.env.supportsLengthTechnique = false; fixture.organizer.tick()
        XCTAssertTrue(fixture.items.active.isEmpty)
        XCTAssertNotNil(fixture.organizer.menuNotice)
        XCTAssertEqual(fixture.organizer.menuNotice, fixture.organizer.issue)
        fixture.organizer.stop()
        XCTAssertNil(fixture.organizer.menuNotice, "Switched off is not a failure to explain")

        fixture.env.supportsLengthTechnique = true; fixture.env.competingOrganizer = true
        fixture.organizer.configure(enabled: true, settings: MenuBarPreferences())
        XCTAssertEqual(fixture.organizer.menuNotice, fixture.organizer.issue)
        XCTAssertNotNil(fixture.organizer.menuNotice)
        fixture.organizer.stop()
    }

    func testTimerLooksTwiceASecondOnlyWhileSomethingWaitsOnTheClockOrThePointer() {
        let fixture = OrganizerFixture(); fixture.automaticTicks = true
        let organizer = fixture.organizer
        XCTAssertNil(organizer.scheduledTickInterval, "No helpers, no timer")
        var settings = MenuBarPreferences(); settings.autoHideSeconds = 5
        organizer.configure(enabled: true, settings: settings)
        XCTAssertEqual(organizer.scheduledTickInterval, 0.5, "The order macOS restored is validated without delay")
        organizer.tick()
        XCTAssertEqual(organizer.scheduledTickInterval, 0.5, "Shown icons wait for the auto-hide delay")
        fixture.time = 5; organizer.tick()
        XCTAssertFalse(organizer.isExpanded)
        XCTAssertEqual(organizer.scheduledTickInterval, 0.5, "The spacer's new width gets its second to settle")
        fixture.time = 6; organizer.tick()
        XCTAssertEqual(organizer.scheduledTickInterval, 2, "Hidden icons leave only the arrangement to check")

        settings.hoverToReveal = true
        organizer.configure(enabled: true, settings: settings); organizer.tick()
        XCTAssertFalse(organizer.isExpanded)
        XCTAssertEqual(organizer.scheduledTickInterval, 0.5, "Hover reveal has to notice the pointer")
        settings.hoverToReveal = false; settings.autoHide = false
        organizer.configure(enabled: true, settings: settings)
        XCTAssertEqual(organizer.scheduledTickInterval, 0.5, "Changed settings are validated without delay")
        organizer.tick()
        XCTAssertEqual(organizer.scheduledTickInterval, 2)

        organizer.toggle()
        XCTAssertTrue(organizer.isExpanded)
        XCTAssertEqual(organizer.scheduledTickInterval, 0.5, "A click does not wait for the resting pace")
        fixture.time = 7; organizer.tick()
        XCTAssertEqual(organizer.scheduledTickInterval, 2, "Shown icons that never hide by themselves wait for nothing")

        fixture.items.reversed = true; organizer.tick()
        XCTAssertNotNil(organizer.issue)
        XCTAssertEqual(organizer.scheduledTickInterval, 0.5, "A problem is rechecked until it is gone")
        fixture.items.reversed = false; organizer.tick()
        XCTAssertNil(organizer.issue)
        XCTAssertEqual(organizer.scheduledTickInterval, 2)

        organizer.setEditingArrangement(true)
        XCTAssertEqual(organizer.scheduledTickInterval, 0.5, "Arranging shows a wrong order while it is being made")
        organizer.setEditingArrangement(false)
        XCTAssertEqual(organizer.scheduledTickInterval, 2)

        fixture.env.mouseDown = true; organizer.tick()
        XCTAssertEqual(organizer.scheduledTickInterval, 0.5, "A drag may rearrange the bar, so its end is not left waiting")
        fixture.env.mouseDown = false; organizer.tick()
        XCTAssertEqual(organizer.scheduledTickInterval, 2)

        fixture.env.competingOrganizer = true; organizer.tick()
        XCTAssertNil(organizer.scheduledTickInterval, "Removed helpers need no timer")
        fixture.env.competingOrganizer = false
        organizer.configure(enabled: true, settings: settings)
        XCTAssertEqual(organizer.scheduledTickInterval, 0.5)
        organizer.stop()
        XCTAssertNil(organizer.scheduledTickInterval)
    }

    func testStartCollapsedKeepsLookingUntilThePointerHasLeftTheMenuBar() {
        let fixture = OrganizerFixture(); fixture.automaticTicks = true
        var settings = MenuBarPreferences(); settings.startCollapsed = true; settings.autoHide = false
        fixture.env.pointerInMenuBar = true
        fixture.organizer.configure(enabled: true, settings: settings)
        fixture.organizer.tick(); fixture.time = 3; fixture.organizer.tick()
        XCTAssertTrue(fixture.organizer.isExpanded)
        XCTAssertEqual(fixture.organizer.scheduledTickInterval, 0.5)
        fixture.env.pointerInMenuBar = false; fixture.organizer.tick()
        XCTAssertFalse(fixture.organizer.isExpanded)
        fixture.time = 4; fixture.organizer.tick()
        XCTAssertEqual(fixture.organizer.scheduledTickInterval, 2)
        fixture.organizer.stop()
    }

    func testChangedDisplayIsLookedAtSoonAndUntilTheMenuBarIsBack() {
        let fixture = OrganizerFixture(); fixture.automaticTicks = true
        var settings = MenuBarPreferences(); settings.autoHide = false
        fixture.organizer.configure(enabled: true, settings: settings)
        fixture.organizer.tick(); fixture.organizer.toggle()
        fixture.time = 1; fixture.organizer.tick()
        XCTAssertEqual(fixture.organizer.scheduledTickInterval, 2)
        XCTAssertEqual(fixture.items.lengths[.divider], 2880)
        // A wider display is connected; the helpers' windows are gone while the bar is rebuilt.
        fixture.env.screens.append(OrganizerScreen(frame: CGRect(x: -4000, y: 0, width: 4000, height: 2000), menuRegions: []))
        fixture.items.framesAvailable = false
        fixture.organizer.screensChanged()
        XCTAssertEqual(fixture.organizer.scheduledTickInterval, 0.5, "A wider display must not wait for the resting pace")
        XCTAssertEqual(fixture.items.lengths[.divider], 2880, "Frames that still belong to the old arrangement are not judged")
        fixture.time = 1.5; fixture.organizer.tick()
        XCTAssertEqual(fixture.organizer.scheduledTickInterval, 0.5, "Nothing could be applied yet")
        fixture.items.framesAvailable = true
        fixture.time = 2; fixture.organizer.tick()
        XCTAssertEqual(fixture.items.lengths[.divider], 8000)
        XCTAssertFalse(fixture.organizer.isExpanded)
        fixture.time = 3; fixture.organizer.tick()
        XCTAssertEqual(fixture.organizer.scheduledTickInterval, 2)
        fixture.organizer.stop()
        fixture.organizer.screensChanged()
        XCTAssertNil(fixture.organizer.scheduledTickInterval, "A late notification starts nothing")
    }

    func testHelpersLeaveAtTheirCompactWidthAlsoWhenTheOrganizerIsReleased() {
        let fixture = OrganizerFixture()
        var settings = MenuBarPreferences(); settings.startCollapsed = true
        for released in [false, true] {
            fixture.items.removedLengths = [:]
            var organizer: MenuBarOrganizer? = MenuBarOrganizer(statusItems: fixture.items, 
                applications: fixture.applications, automaticTicks: false, environment: { fixture.env }, now: { fixture.time })
            organizer?.configure(enabled: true, settings: settings)
            organizer?.tick()
            XCTAssertEqual(organizer?.isExpanded, false)
            XCTAssertEqual(fixture.items.lengths[.divider], 2880)
            if released { organizer = nil } else { organizer?.stop() }
            XCTAssertTrue(fixture.items.active.isEmpty)
            // The saved placement of a helper taken out wide would be off by its inflated width.
            XCTAssertEqual(fixture.items.removedLengths, [.toggle: 24, .divider: 18],
                           released ? "Releasing the organizer" : "Switching it off")
        }
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
    let applications = FixtureOrganizerApplications()
    /// Set before the organizer is first used. The timer is only scheduled, a test never waits for it.
    var automaticTicks = false
    var time: TimeInterval = 0
    var env = OrganizerEnvironment(screens: [OrganizerScreen(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        menuRegions: [CGRect(x: 0, y: 876, width: 1440, height: 24)])])
    lazy var organizer = MenuBarOrganizer(statusItems: items, applications: applications, automaticTicks: automaticTicks,
        environment: { [unowned self] in self.env }, now: { [unowned self] in self.time })
}

@MainActor private final class FixtureOrganizerItems: OrganizerStatusItems {
    var created: [OrganizerItem] = []
    var active = Set<OrganizerItem>()
    var lengths: [OrganizerItem: CGFloat] = [:]
    var reversed = false
    var framesAvailable = true
    var delaysLayout = false
    var bar: (y: CGFloat, height: CGFloat) = (876, 24)
    /// What the system adds around an item's own length.
    var padding: CGFloat = 0
    private var pendingOrigins: [OrganizerItem: CGFloat] = [:]
    func settleLayout() { pendingOrigins.removeAll() }
    var menuState: OrganizerMenuState?
    var menuAction: ((OrganizerMenuAction) -> Void)?
    var menuActionsSet = 0
    func setMenuAction(_ action: @escaping (OrganizerMenuAction) -> Void) { menuAction = action; menuActionsSet += 1 }
    func updateMenu(_ state: OrganizerMenuState) { menuState = state }
    func install(_ item: OrganizerItem) {
        created.append(item); active.insert(item)
    }
    /// The length each helper had when it was taken out of the bar.
    var removedLengths: [OrganizerItem: CGFloat] = [:]
    func remove(_ item: OrganizerItem) { removedLengths[item] = lengths[item]; active.remove(item); lengths[item] = nil }
    func setLength(_ length: CGFloat, for item: OrganizerItem) {
        if delaysLayout, lengths[item] != length, let old = frame(of: item) { pendingOrigins[item] = old.minX }
        lengths[item] = length
    }
    func setExpanded(_ expanded: Bool) {}
    func frame(of item: OrganizerItem) -> CGRect? {
        guard framesAvailable, active.contains(item) else { return nil }
        let width = lengths[item] ?? 18
        // The divider's window ends where the arrow's begins.
        let dividerRight = 1300 - (lengths[.toggle] ?? 24) - padding
        let right: CGFloat
        switch item {
        case .toggle: right = reversed ? 900 : 1300
        case .divider: right = dividerRight
        case .permanentDivider: right = dividerRight - (lengths[.divider] ?? 18) - padding - 100
        }
        return CGRect(x: pendingOrigins[item] ?? right - width - padding, y: bar.y, width: width + padding, height: bar.height)
    }
}

@MainActor private final class FixtureOrganizerApplications: OrganizerApplications {
    var changed: (() -> Void)?
    func watch(_ changed: @escaping () -> Void) { self.changed = changed }
    func stopWatching() { changed = nil }
}
