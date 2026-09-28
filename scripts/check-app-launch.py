#!/usr/bin/env python3
"""Smoke-test packaged dynamic-library loading with isolated Frog data."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

app = Path(sys.argv[1] if len(sys.argv) > 1 else "dist/Frog.app").resolve()
with tempfile.TemporaryDirectory(prefix="frog-launch-") as directory:
    environment = dict(os.environ, FROG_DATA_DIRECTORY=directory)
    with tempfile.TemporaryFile() as output:
        process = subprocess.Popen(
            [str(app / "Contents/MacOS/Frog"), "--background"],
            env=environment, stdout=output, stderr=output,
        )
        try:
            status = process.wait(timeout=5)
            output.seek(0)
            print(output.read().decode(errors="replace"), file=sys.stderr)
            sys.exit(f"Frog exited during startup ({status}).")
        except subprocess.TimeoutExpired:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            print("PASS: packaged Frog survived startup with isolated data.")
