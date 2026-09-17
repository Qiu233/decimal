"""Run the same correctness checks on every supported CI platform."""

import os
import subprocess
import sys


def main():
    prefix = os.environ["MPDEC_PREFIX"]
    compiler = os.environ["MPDEC_CC"]
    lake = ["lake", f"-KmpdecPrefix={prefix}", f"-KmpdecCC={compiler}"]
    for command in [
        [*lake, "build", "Decimal", "decimal", "decimalTests", "decimalOracle", "decimalBench"],
        [sys.executable, ".github/scripts/release.py", "check-linkage"],
        [*lake, "test"],
        [sys.executable, "tests/differential.py"],
        [sys.executable, "tests/build_integration.py", "--prefix", prefix, "--cc", compiler],
    ]:
        print("Running:", command, flush=True)
        subprocess.run(command, check=True)


if __name__ == "__main__":
    main()
