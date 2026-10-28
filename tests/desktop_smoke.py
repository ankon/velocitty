"""Exercise the real native window, Unicode CLI/cwd, PTY and child-exit path."""
from pathlib import Path
import os
import subprocess
import sys
import tempfile

binary = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="velocitty-smoke-") as temp:
    cwd = Path(temp) / "working directory é"
    cwd.mkdir()
    if os.name == "nt":
        command = ["cmd.exe", "/d", "/c", "echo velocitty-port-ready>port.txt & echo terminal-output & ping -n 2 127.0.0.1 >nul"]
    else:
        command = ["/bin/sh", "-c", "printf '\\033[32mterminal-output\\033[0m\\n'; printf velocitty-port-ready >port.txt; sleep 1"]
    result = subprocess.run(
        [str(binary), "--working-directory", str(cwd), "--title=Velocitty smoke test", "-e", *command],
        capture_output=True, timeout=30,
    )
    if result.returncode:
        raise RuntimeError(f"native app failed ({result.returncode}): {result.stderr.decode(errors='replace')}")
    assert (cwd / "port.txt").read_text().strip() == "velocitty-port-ready"
    print("Native window/PTY smoke passed, including Unicode cwd and child exit.")
