#!/usr/bin/env python3
"""Keep trusted timestamps mandatory while retrying transient Apple TSA failures."""

import subprocess
import sys
import time


def sign(arguments):
    if "--sign" not in arguments or "--timestamp" not in arguments or any(
        value.startswith("--timestamp=") for value in arguments
    ):
        raise ValueError("Signing requires --sign and an Apple --timestamp")
    command = ["/usr/bin/codesign", *arguments]
    for attempt in range(1, 6):
        try:
            result = subprocess.run(
                command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT, text=True, timeout=120, check=False,
            )
            output = result.stdout or ""
            print(output[-8000:], end="" if output.endswith("\n") else "\n", flush=True)
            if result.returncode == 0:
                return
            transient = "timestamp service is not available" in output.lower()
            failure = subprocess.CalledProcessError(result.returncode, command, output=output)
        except subprocess.TimeoutExpired as error:
            print("codesign timed out after 120 seconds", flush=True)
            transient, failure = True, error
        if not transient or attempt == 5:
            raise failure
        delay = min(10 * 2 ** (attempt - 1), 60)
        print(f"Retrying timestamped signature in {delay}s (attempt {attempt + 1}/5)", flush=True)
        time.sleep(delay)


if __name__ == "__main__":
    sign(sys.argv[1:])
