# Native verification

## Automated and build checks

The native app builds through Swift Package Manager and Xcode. A successful build is separate from verifying external text replacement or login startup.

Commands:

```sh
swift test
bash scripts/build-app.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project native/Frog.xcodeproj -scheme Frog-macOS -configuration Debug -derivedDataPath .build/xcode build
```

## Desktop acceptance checklist

Use an installed signed app and a disposable document. Record macOS version, architecture, source application/version, provider/model, and result for each case.

- Open menu-bar settings; close/reopen the window; Quit actually exits and releases shortcuts.
- Configure a cloud provider with your own key and test it; repeat with Ollama/local compatible service. An invalid key, unavailable model, offline server, rate limit and empty reply produce actionable errors.
- Verify credentials are absent from settings/history files. Blank key retains saved key; explicit removal and provider deletion remove it.
- Assign different providers/models to two rules, and two languages to translation rules; verify each hotkey uses its own settings after restart.
- In TextEdit and a browser text field, select multiline Unicode text, run a rule, verify replacement and clipboard result. The main window stays hidden and focus stays in the source application.
- In Helium/Chromium, repeat with the Accessibility tree initially unavailable. A Copy fallback must use only a fresh selection, preserve the previous clipboard during capture, and leave final results copied. Compare actual edited content, not just an AX success return. Repeat after clicking elsewhere or typing during the request: replacement must be skipped.
- Keep a service menu open for several seconds while permission monitoring runs; icons must remain stable. Delete the last provider with referencing rules, confirm the reset and verify rules remain. In Try text, choose another configured provider/model and verify the saved rule stays unchanged.
- Toggle **Show processing indicator** off/on; hotkey progress must obey the preference and never take focus. Check both success and errors, and confirm manual Try text requests do not show the floating indicator.
- Repeat with no selection, a read-only field, missing Accessibility permission, changed focus, changed selection, and edits during the request. Original text must not be overwritten in these cases.
- Trigger multiple shortcuts rapidly, cancel an in-flight request, and quit while processing. Requests must not cross-apply results.
- Test invalid/duplicate/occupied global hotkeys and remove or disable a rule; registration state must match the UI.
- With a legacy rule assigned Command-C, launch Frog and copy/cut/paste in a disposable document. Clipboard shortcuts must stay with the focused app, with no Frog processing or popup. Assigning these shortcuts to a new rule must be rejected.
- Local workflows: automated fixture tests cover config migration, action routing, incomplete download cleanup, installed-state recovery, idle unload and cancellation/stale completion during insertion. `swift scripts/check-metal.swift <bundled default.metallib>` verifies actual shader loading without microphone/desktop access. Xcode package-plugin validation may require approval for MLX's CUDA build plugin (inactive on macOS); scripted builds can use `-skipPackagePluginValidation` after inspecting that pinned plugin.
- Download speech and cleanup models; record with both toggle and hold modes, view partial text and stop/cancel hints, disable popup, verify copy/paste and shared-history behavior. Exercise missing/disconnected microphone, cancellation during permission/model load/paste, and model idle unload. Verify application launch/focus and the momentary shortcut reference. These live behaviors are separate from fixture tests.
- With models unloaded, start dictation: show Preparing and the model being loaded, keep the microphone closed and timer hidden until every required local model is ready. Release a hold shortcut during preparation: recording must never start later. Disable cleanup and confirm no text model is prepared; required models must stay resident throughout recording.
- Pause speaking with a connected microphone: silence must not show "No microphone input". Stop audio-buffer delivery or disconnect the input and verify the warning appears after two seconds, then clears when buffers resume.
- Switch Local/External in an audio rule's model picker, including an empty source. Installed choices must appear promptly without loading weights, with download sizes and Recommended labels. Delete a selected model and verify affected rules choose another compatible model; local rules stay local. Inspect the sidebar's named audio/text memory list and copy an error or the complete log.
- Window switcher: open several windows in one app plus another app, hold Command and cycle with Tab/Shift–Tab/arrows, then release to activate the exact selected window. Test Escape, Return, hovering/clicking a row, rapid press/release before discovery finishes, closing a target during discovery, hidden/minimized targets, and other Spaces/full-screen applications. Opening/cancelling the overlay must not activate Frog or change the source window.
- Disable window switching, quit Frog, revoke Accessibility, and enter shortcut-recording mode: interception must stop and the native shortcut must remain available. An enabled writing rule assigned Command–Tab must retain its shortcut and show the conflict in Windows. Permission/status polling must not redraw unchanged menus.
- Enable history, process manually and by hotkey, relaunch, inspect/copy/delete/clear records. Disable recording during a request; its result must not be recorded. Verify configured bounds/expiry.
- Export a configuration, edit a rule and import it again. Verify the replacement summary, backup file, provider routing and shortcut registration. Invalid JSON/references/shortcuts leave current settings untouched. Exported JSON contains neither API keys nor text history. Re-enter keys for new/changed connections on import.
- Enable Start at Login for `/Applications/Frog.app`, inspect Login Items approval, log out/in and confirm the menu icon appears without the settings window. Disable startup and confirm removal.
- Confirm Frog never requests notification permission or sends system notifications. Errors stay in the app and can be copied from Settings → Logs.
- Measure idle CPU/RSS after startup and with settings closed; verify no inference engine is launched by Frog. Resource budgets are measured evidence, not a hard-coded marketing claim.

## Distribution

Developer ID signing/notarization requires the owner's Apple Developer credentials. Ad-hoc signing is suitable for local development, but is not notarization and does not establish that macOS will trust a downloaded release on another machine.
