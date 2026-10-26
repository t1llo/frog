#!/usr/bin/env python3
"""Check that the bundled `frog` tool talks to the packaged app, with isolated Frog data."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

app = Path(sys.argv[1] if len(sys.argv) > 1 else "dist/Frog.app").resolve()
tool = app / "Contents/Helpers/frog"
if not os.access(tool, os.X_OK):
    sys.exit(f"{tool} is missing or not executable.")
# A short folder keeps the socket path under the 104-byte limit of Unix sockets.
with tempfile.TemporaryDirectory(prefix="frog-agent-", dir="/tmp") as directory:
    # No shortcuts, inference or real user settings; only agent access is on.
    configuration = {"version": 1, "providers": [], "rules": [], "explicitRuleModels": True,
        "preferences": {"historyEnabled": False, "historyLimit": 200, "historyRetentionDays": 30,
            "windowSwitcherEnabled": False, "applicationShortcutsEnabled": False,
            "toolkit": {"agentAccess": True},
            "workflows": {"audioModelID": "whisper-tiny", "cleanupModelID": "qwen-0.6b",
                "recordingMode": "toggle", "output": "copy", "idleUnloadSeconds": 120,
                "showDictationPopup": False, "dictationDefaultsVersion": 1}}}
    Path(directory, "config.json").write_text(json.dumps(configuration))
    environment = dict(os.environ, FROG_DATA_DIRECTORY=directory)

    def frog(*words):
        return subprocess.run([str(tool), *words], env=environment, capture_output=True, text=True, timeout=30)

    with tempfile.TemporaryFile() as output:
        process = subprocess.Popen([str(app / "Contents/MacOS/Frog")], env=environment, stdout=output, stderr=output)
        try:
            deadline = time.monotonic() + 20
            while not Path(directory, "agent.sock").exists():
                if process.poll() is not None or time.monotonic() > deadline:
                    output.seek(0)
                    print(output.read().decode(errors="replace"), file=sys.stderr)
                    sys.exit("Frog did not open its agent socket.")
                time.sleep(0.2)
            if (Path(directory, "agent.sock").stat().st_mode & 0o777) != 0o600:
                sys.exit("The agent socket is not owner-only.")
            version = frog("--version")
            status = frog("status", "--json")
            help_text = frog("help")
            unknown = frog("teleport")
            checks = {
                "--version names the app's version": version.returncode == 0 and version.stdout.startswith("frog "),
                "status --json answers": status.returncode == 0 and "featuresOn" in json.loads(status.stdout or "{}"),
                "help lists commands": help_text.returncode == 0 and "features list" in help_text.stdout,
                "unknown words exit 2": unknown.returncode == 2 and "frog help" in unknown.stderr,
            }
            failed = [name for name, passed in checks.items() if not passed]
            if failed:
                print(status.stdout, status.stderr, help_text.stderr, unknown.stderr, sep="\n", file=sys.stderr)
                sys.exit("Failed: " + ", ".join(failed))
            print(f"PASS: {version.stdout.strip()} reached the packaged app over its socket.")
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
