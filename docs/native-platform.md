# Native platform implementation

Owned implementation: `native/FrogApp/Platform`. All contract APIs are implemented. `LoginService` and `DesktopNotifications` expose static methods/properties; selection and hotkey manager instances are main-actor isolated.

## Behavior

- Selection capture reads Accessibility attributes only, retaining selected text verbatim, including whitespace. It never issues Copy or changes the pasteboard, preserving rich/private clipboard formats. Applications without a reliable AX range and selected text (or range into an exposed value) receive an actionable error directing them to Try text.
- A selection retains its AX element, process ID, UTF-16 range, available full value, and focused window. Replacement first writes the result to the clipboard, then verifies the original foreground process, focused element/window, range, value and text. Switching applications invalidates the capture even if the user switches back. AX notifications invalidate captures on selection/value/focus changes or element destruction when supported.
- Replacement uses only settable `AXSelectedText`, never whole-document `AXValue`. An unsuccessful AX write is not retried, since an application may have partially applied it.
- CGEvent paste fallback requires successful selection/value/focus observation, an unchanged full value/window, an enabled/focused text field or text area with settable value, and released physical modifiers. Final validation and the process-targeted Command-V event pair have no intervening suspension. Unsupported targets retain the result on the clipboard with an explanatory error. macOS does not expose an atomic cross-process compare-and-paste primitive: app-internal mutation between validation and event handling cannot be completely eliminated, and event delivery does not acknowledge insertion.
- Carbon handlers listen for key release. Registration replaces the previous set, rejects all duplicates, invalid key codes and unsupported modifiers, and returns per-rule errors. Deferred main-actor callbacks are generation-checked so unregister/re-register drops stale callbacks. Display uses the current keyboard layout plus native special-key labels. Recorder accepts Command/Option/Control combinations; Shift alone and bare keys are rejected.
- Login startup uses `SMAppService.mainApp`. Parent must surface `statusText`, including approval/install states, and catch registration errors.
- Notifications never prompt during posting. Call `requestAuthorization()` from an explicit onboarding/settings action. Parent must keep processing/error status visible in its menu regardless of notification authorization. Unbundled CLI execution skips notifications.

## Verification (platform branch)

Compiled shared Models.swift as an isolated FrogCore module/library, then compiled and linked all four platform files against it using Xcode's Swift 6.3.3, `-swift-version 6 -warnings-as-errors -target arm64-apple-macos14.0`. This is stricter than the package's Swift 5 language mode. Cleanup uses isolated deinitializers (Swift 6.2+ compiler) so Carbon and AX sources are removed on the main actor.

Standalone smoke executable passed recorder conversion to preset bits, Shift-only/modifier-key/repeat rejection, special-key display, duplicate conflicts, invalid codes/modifiers, ignored disabled rules, empty registration, and unregister. Isolated smoke source and products are at `/private/var/folders/vg/3zs65d3577nb3kt42wfrvzzh0000gn/T/opencode/frog-platform-check`; no package or parent-owned test files were changed.

## Desktop verification still required

In the packaged app with user-granted Accessibility:

1. Select whitespace-rich and emoji text in TextEdit; verify capture leaves rich clipboard contents intact and replacement changes only the selection, retaining surrounding formatting.
2. During an in-flight request, change selection, edit text, switch controls/windows/apps, close the document, or terminate the target. Expect clipboard-only output rather than replacement. Repeat switching away and back.
3. Test direct AX write and a supported paste-fallback control. Unsupported browser/custom controls should fail closed with output on the clipboard. Hold modifiers through completion and verify paste fallback is refused.
4. Exercise actual global key release, shortcut conflicts with another app, changing rules, and app shutdown.
5. From an installed signed app, check SMAppService approval, login launch and unregister. Check notification allow/deny behavior and visible menu status in both cases.

These user-session behaviors have not been claimed as verified by compilation or the smoke executable.
