# Native verification

## Automated and build checks

The native app builds through Swift Package Manager and Xcode. Actual evidence is recorded in `status.md`; a successful build is separate from external text replacement or login startup.

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
- Enable history, process manually and by hotkey, relaunch, inspect/copy/delete/clear records. Disable recording during a request; its result must not be recorded. Verify configured bounds/expiry.
- Export a configuration, edit a rule and import it again. Verify the replacement summary, backup file, provider routing and shortcut registration. Invalid JSON/references/shortcuts leave current settings untouched. Exported JSON contains neither API keys nor text history. Re-enter keys for new/changed connections on import.
- Enable Start at Login for `/Applications/Frog.app`, inspect Login Items approval, log out/in and confirm the menu icon appears without the settings window. Disable startup and confirm removal.
- Deny notification permission; processing failures remain visible from the menu/settings. Allow notifications and verify useful messages without including selected text.
- Measure idle CPU/RSS after startup and with settings closed; verify no inference engine is launched by Frog. Resource budgets are measured evidence, not a hard-coded marketing claim.

## Distribution

Developer ID signing/notarization requires the owner's Apple Developer credentials. Ad-hoc signing is suitable for local development, but is not notarization and does not establish that macOS will trust a downloaded release on another machine.
