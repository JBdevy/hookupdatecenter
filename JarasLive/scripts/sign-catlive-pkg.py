#!/usr/bin/env python3
"""Sign an already-built CatLive package without letting productbuild hang forever."""

import os
from pathlib import Path
import signal
import subprocess
import sys
import time


def sign_package(source: Path, destination: Path, identity: str, keychain: str) -> None:
    for attempt in range(1, 4):
        destination.unlink(missing_ok=True)
        command = [
            "/usr/bin/productbuild", "--timestamp", "--sign", identity,
            "--keychain", keychain, "--package", str(source), str(destination),
        ]
        print(f"Signing installer (attempt {attempt}/3, {source.stat().st_size} bytes)", flush=True)
        process = subprocess.Popen(
            command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, start_new_session=True,
        )
        try:
            output, _ = process.communicate(timeout=240)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            output, _ = process.communicate()
            print(f"productbuild timed out after 240 seconds.\n{output[-8000:]}", flush=True)
        else:
            print(output[-8000:], flush=True)
            if process.returncode == 0 and destination.is_file():
                return
            print(f"productbuild exited with status {process.returncode}.", flush=True)
        if attempt < 3:
            time.sleep(10)
    raise RuntimeError("Could not sign the CatLive installer with a trusted timestamp")


if __name__ == "__main__":
    if len(sys.argv) != 5:
        raise SystemExit("usage: sign-catlive-pkg.py unsigned.pkg signed.pkg identity keychain")
    sign_package(Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3], sys.argv[4])
