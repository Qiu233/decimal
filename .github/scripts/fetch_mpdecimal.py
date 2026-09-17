"""Explicit GitHub Actions provisioning; never called by Lake or downstream builds."""

import hashlib
import os
from pathlib import Path
import tarfile
import time
import urllib.error
import urllib.request

VERSION = "4.0.1"
SHA256 = "96d33abb4bb0070c7be0fed4246cd38416188325f820468214471938545b1ac8"
URL = f"https://www.bytereef.org/software/mpdecimal/releases/mpdecimal-{VERSION}.tar.gz"


def main():
    if os.environ.get("GITHUB_ACTIONS") != "true":
        raise SystemExit("This downloader is for explicit CI provisioning only; install libmpdec yourself.")
    work = Path(os.environ["RUNNER_TEMP"]) / "decimal-dependency"
    work.mkdir()
    archive = work / "mpdecimal.tar.gz"
    print(f"Downloading mpdecimal {VERSION} from {URL}", flush=True)
    for attempt in range(3):
        try:
            with urllib.request.urlopen(URL, timeout=60) as response:
                data = response.read()
            break
        except (urllib.error.URLError, TimeoutError):
            if attempt == 2:
                raise
            time.sleep(2 ** attempt)
    if hashlib.sha256(data).hexdigest() != SHA256:
        raise SystemExit("mpdecimal source SHA-256 does not match the pinned upstream checksum")
    archive.write_bytes(data)
    with tarfile.open(archive) as source:
        source.extractall(work, filter="data")
    prefix = (work / "install").as_posix()
    values = {
        "MPDEC_SOURCE": (work / f"mpdecimal-{VERSION}").as_posix(),
        "MPDEC_PREFIX": prefix,
        "MPDEC_CC": "clang",
    }
    with open(os.environ["GITHUB_ENV"], "a", encoding="utf-8") as output:
        for key, value in values.items():
            output.write(f"{key}={value}\n")
    print(f"Verified mpdecimal {VERSION}; CI installation prefix: {prefix}")


if __name__ == "__main__":
    main()
