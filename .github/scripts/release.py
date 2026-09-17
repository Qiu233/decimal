"""Validate, pack, and publish tested Lake archives with statically linked libmpdec."""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tarfile

LICENSE_PATH = "licenses/mpdecimal-COPYRIGHT.txt"


def run(*args):
    return subprocess.check_output(args, text=True, encoding="utf-8").strip()


def lake(*args):
    return run("lake", f"-KmpdecPrefix={os.environ['MPDEC_PREFIX']}",
               f"-KmpdecCC={os.environ['MPDEC_CC']}", *args)


def verify_ref():
    if os.environ["GITHUB_REF"] != "refs/heads/" + os.environ["DEFAULT_BRANCH"]:
        raise SystemExit("Releases must run from the repository's default branch.")
    tag, revision = os.environ["RELEASE_TAG"], os.environ["GITHUB_SHA"]
    run("git", "check-ref-format", "refs/tags/" + tag)
    if run("git", "rev-parse", "HEAD") != revision:
        raise SystemExit("The checkout does not match the workflow commit.")
    refs = dict(line.split()[::-1] for line in run(
        "git", "ls-remote", "--tags", "origin", f"refs/tags/{tag}", f"refs/tags/{tag}^{{}}"
    ).splitlines())
    target = refs.get(f"refs/tags/{tag}^{{}}", refs.get(f"refs/tags/{tag}"))
    if target is not None and target != revision:
        raise SystemExit(f"Tag {tag} already points to {target}, not {revision}.")
    return tag, revision, target is not None


def validate():
    tag, _, _ = verify_ref()
    version = json.loads(lake("reservoir-config"))["version"]
    if tag != "v" + version:
        raise SystemExit(f"Release tag {tag} does not match package version v{version}.")
    print(f"Validated {tag}.")


def digest(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def dependencies(path):
    if sys.platform == "win32":
        output = run("llvm-readobj", "--coff-imports", str(path))
        return re.findall(r"^\s*Name:\s*(\S+)", output, re.MULTILINE)
    if sys.platform == "darwin":
        output = run("otool", "-L", str(path))
        return [line.strip().split(" (", 1)[0] for line in output.splitlines()[1:]]
    if sys.platform.startswith("linux"):
        output = run("readelf", "--wide", "--dynamic", str(path))
        return re.findall(r"\(NEEDED\).*?\[([^\]]+)\]", output)
    raise SystemExit(f"Unsupported release platform: {sys.platform}")


def verify_static_linkage():
    libdir = Path(os.environ["MPDEC_PREFIX"]) / "lib"
    if not (libdir / "libmpdec.a").is_file():
        raise SystemExit("Release builds require a static libmpdec.a installation.")
    for pattern in ["libmpdec*.so*", "libmpdec*.dylib", "libmpdec*.dll*", "mpdec.lib"]:
        if any(libdir.glob(pattern)):
            raise SystemExit("Release builds require a prefix containing only static libmpdec.")
    build = Path(".lake/build")
    suffix = ".exe" if sys.platform == "win32" else ""
    executables = [build / "bin" / (name + suffix) for name in
                   ["decimal", "decimalTests", "decimalOracle", "decimalBench"]]
    for path in executables:
        if not path.is_file():
            raise SystemExit(f"Missing native executable: {path}")
    modules = sorted(path for path in (build / "lib").rglob("*")
                     if path.is_file() and path.suffix in {".so", ".dylib", ".dll"})
    if not modules:
        raise SystemExit("Missing native shared modules; build Decimal before packing.")
    for path in [*executables, *modules]:
        for dependency in dependencies(path):
            name = PurePosixPath(dependency.replace("\\", "/")).name.lower()
            if name.startswith(("libmpdec", "mpdec")):
                raise SystemExit(f"Dynamic libmpdec dependency in {path}: {dependency}")
    print(f"Verified {len(executables) + len(modules)} native outputs: no dynamic libmpdec dependencies.")


def verify_archive(path):
    with tarfile.open(path, "r:gz") as archive:
        names = set()
        for member in archive:
            name = PurePosixPath(member.name)
            if name.is_absolute() or ".." in name.parts:
                raise SystemExit(f"Invalid archive path: {member.name}")
            if name.name.lower().startswith(("libmpdec", "mpdecimal.h")):
                raise SystemExit(f"Unexpected standalone libmpdec file: {member.name}")
            names.add(str(name))
        required = {"lib/lean/Decimal.olean", "lib/lean/Decimal/Basic.olean",
                    "lib/lean/Decimal/Context.olean", "lib/lean/Decimal/Model.olean",
                    "lib/lean/Decimal/Proofs.olean", LICENSE_PATH}
        if not required <= names:
            raise SystemExit(f"Archive is missing modules or the libmpdec license: {required - names}")


def pack():
    verify_static_linkage()
    # Binary redistribution must carry the copyright, conditions, and disclaimer.
    license_file = Path(".lake/build") / LICENSE_PATH
    license_file.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(Path(os.environ["MPDEC_SOURCE"]) / "COPYRIGHT.txt", license_file)
    print(lake("pack"))
    archives = list(Path(".lake").glob("decimal-*.tar.gz"))
    if len(archives) != 1:
        raise SystemExit(f"Expected one platform archive, found {len(archives)}.")
    archive = archives[0]
    verify_archive(archive)
    Path(str(archive) + ".sha256").write_text(
        f"{digest(archive)}  {archive.name}\n", encoding="utf-8")
    print(f"Verified {archive}.")


def publish():
    tag, revision, exists = verify_ref()
    archives = sorted(Path("dist").glob("decimal-*.tar.gz"))
    if len(archives) != 4:
        raise SystemExit(f"Expected four platform archives, found {len(archives)}.")
    checksums = []
    for archive in archives:
        verify_archive(archive)
        checksum = f"{digest(archive)}  {archive.name}\n"
        if Path(str(archive) + ".sha256").read_text(encoding="utf-8") != checksum:
            raise SystemExit(f"Checksum mismatch: {archive}")
        checksums.append(checksum)
    sums = Path("dist/SHA256SUMS")
    sums.write_text("".join(checksums), encoding="utf-8")
    if not exists:
        run("git", "-c", "user.name=github-actions[bot]", "-c",
            "user.email=41898282+github-actions[bot]@users.noreply.github.com",
            "tag", "-a", tag, revision, "-m", f"decimal {tag}")
        run("git", "push", "origin", f"refs/tags/{tag}")
    # Recheck the remote immediately before modifying release assets, including on retries.
    verify_ref()
    assets = [str(p) for p in [*archives, sums]]
    result = subprocess.run(["gh", "release", "view", tag], capture_output=True)
    if result.returncode == 0:
        run("gh", "release", "upload", tag, *assets, "--clobber")
    else:
        run("gh", "release", "create", tag, *assets, "--verify-tag", "--generate-notes",
            "--title", tag, "--notes",
            "Lake build archives for the pinned Lean toolchain, with libmpdec 4.0.1 linked "
            "statically and its license included. No libmpdec shared library is needed at runtime. "
            "Install libmpdec headers and a static library separately for downstream Lake builds. "
            "See README.md for platform setup and verify downloads with SHA256SUMS.")
    published = json.loads(run("gh", "release", "view", tag, "--json", "assets"))["assets"]
    by_name = {asset["name"]: asset for asset in published}
    with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as summary:
        for path in [*archives, sums]:
            asset = by_name.get(path.name)
            if asset is None or asset["size"] != path.stat().st_size:
                raise SystemExit(f"Missing or incomplete release asset: {path.name}")
            summary.write(f"- [{path.name}]({asset['url']})\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    commands = {"validate": validate, "check-linkage": verify_static_linkage,
                "pack": pack, "publish": publish}
    parser.add_argument("command", choices=commands)
    commands[parser.parse_args().command]()
