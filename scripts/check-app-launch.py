#!/usr/bin/env python3
"""Verify packaged loading and menu-bar-only startup with isolated Frog data."""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile

app = Path(sys.argv[1] if len(sys.argv) > 1 else "dist/Frog.app").resolve()
with (app / "Contents/Info.plist").open("rb") as file:
    if plistlib.load(file).get("LSUIElement") is not True:
        sys.exit("Frog must be packaged as a menu-bar accessory (LSUIElement=true).")
with tempfile.TemporaryDirectory(prefix="frog-launch-") as directory:
    # No global shortcuts, inference, or real user settings in the launch fixture.
    configuration = {"version": 1, "providers": [], "rules": [], "explicitRuleModels": True,
        "preferences": {"historyEnabled": False, "historyLimit": 200, "historyRetentionDays": 30,
            "windowSwitcherEnabled": False, "applicationShortcutsEnabled": False,
            "workflows": {"audioModelID": "whisper-tiny", "cleanupModelID": "qwen-0.6b",
                "recordingMode": "toggle", "output": "copy", "idleUnloadSeconds": 120,
                "showDictationPopup": False, "dictationDefaultsVersion": 1}}}
    Path(directory, "config.json").write_text(json.dumps(configuration))
    environment = dict(os.environ, FROG_DATA_DIRECTORY=directory)
    with tempfile.TemporaryFile() as output:
        process = subprocess.Popen(
            [str(app / "Contents/MacOS/Frog")],
            env=environment, stdout=output, stderr=output,
        )
        try:
            status = process.wait(timeout=5)
            output.seek(0)
            print(output.read().decode(errors="replace"), file=sys.stderr)
            sys.exit(f"Frog exited during startup ({status}).")
        except subprocess.TimeoutExpired:
            # NSRunningApplication and window metadata need no Accessibility or
            # screen-recording permission. This checks the actual packaged app;
            # xctest is not an app bundle and cannot change activation policy.
            probe = f"""
ObjC.import('AppKit'); ObjC.import('CoreGraphics');
const app = $.NSRunningApplication.runningApplicationWithProcessIdentifier({process.pid});
const windows = ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, $.kCGNullWindowID)));
JSON.stringify({{policy: Number(app.activationPolicy),
    windows: windows.filter(w => w.kCGWindowOwnerPID === {process.pid} && w.kCGWindowLayer === 0).length}});
"""
            result = subprocess.run(["osascript", "-l", "JavaScript", "-e", probe], capture_output=True, text=True, timeout=10)
            if result.returncode != 0:
                sys.exit("Could not inspect packaged startup: " + result.stderr)
            state = json.loads(result.stdout)
            if state != {"policy": 1, "windows": 0}:
                sys.exit(f"Frog did not start quietly in the menu bar: {state}")
            print("PASS: packaged Frog survived startup, uses accessory policy, and opened no main window.")
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
