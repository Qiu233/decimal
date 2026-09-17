"""Offline regression checks for release gates; never contact GitHub or publish assets."""

from contextlib import chdir
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

import release


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        temporary = self.enterContext(tempfile.TemporaryDirectory(prefix="decimal release "))
        self.enterContext(chdir(temporary))
        self.enterContext(patch.dict(os.environ, {
            "MPDEC_PREFIX": str(Path("prefix").resolve()),
            "DEFAULT_BRANCH": "main", "GITHUB_REF": "refs/heads/main",
            "RELEASE_TAG": "v0.1.0", "GITHUB_STEP_SUMMARY": str(Path("summary").resolve()),
        }))

    def init_git(self):
        release.run("git", "init", "--quiet", "--bare", "remote.git")
        Path("repo").mkdir()
        self.enterContext(chdir("repo"))
        release.run("git", "init", "--quiet", "--initial-branch=main")
        release.run("git", "config", "user.name", "Decimal Release Test")
        release.run("git", "config", "user.email", "test@example.invalid")
        release.run("git", "commit", "--quiet", "--allow-empty", "-m", "First commit")
        release.run("git", "remote", "add", "origin", str(Path("../remote.git").resolve()))
        revision = release.run("git", "rev-parse", "HEAD")
        self.enterContext(patch.dict(os.environ, {"GITHUB_SHA": revision}))
        return revision

    def test_tags_are_immutable_and_same_commit_retries_work(self):
        revision = self.init_git()
        self.assertEqual(release.verify_ref(), ("v0.1.0", revision, False))
        for tag, options in [("v0.1.0", []), ("v0.1.1", ["-a", "-m", "Annotated tag"])]:
            with self.subTest(tag=tag), patch.dict(os.environ, {"RELEASE_TAG": tag}):
                release.run("git", "tag", *options, tag)
                release.run("git", "push", "--quiet", "origin", f"refs/tags/{tag}")
                self.assertEqual(release.verify_ref(), (tag, revision, True))
        release.run("git", "commit", "--quiet", "--allow-empty", "-m", "Second commit")
        with patch.dict(os.environ, {"GITHUB_SHA": release.run("git", "rev-parse", "HEAD")}):
            with self.assertRaisesRegex(SystemExit, "already points to"):
                release.verify_ref()

    def test_branch_checkout_and_version_must_match(self):
        self.init_git()
        for key, value, message in [
            ("GITHUB_REF", "refs/heads/topic", "default branch"),
            ("GITHUB_SHA", "0" * 40, "workflow commit"),
        ]:
            with self.subTest(key=key), patch.dict(os.environ, {key: value}):
                with self.assertRaisesRegex(SystemExit, message):
                    release.verify_ref()
        with patch.object(release, "lake", return_value=json.dumps({"version": "0.1.0"})):
            release.validate()
            with patch.dict(os.environ, {"RELEASE_TAG": "v0.2.0"}):
                with self.assertRaisesRegex(SystemExit, "does not match package version"):
                    release.validate()

    def archive(self, name="test.tar.gz", *, omit=None, extra=None):
        files = ["lib/lean/Decimal.olean", "lib/lean/Decimal/Basic.olean",
                 "lib/lean/Decimal/Context.olean", "lib/lean/Decimal/Model.olean",
                 "lib/lean/Decimal/Proofs.olean", "licenses/mpdecimal-COPYRIGHT.txt"]
        if extra:
            files.append(extra)
        path = Path(name)
        path.parent.mkdir(parents=True, exist_ok=True)
        with tarfile.open(path, "w:gz") as archive:
            for filename in files:
                if filename != omit:
                    member = tarfile.TarInfo("./" + filename)
                    member.size = 4
                    archive.addfile(member, io.BytesIO(b"test"))
        return path

    def test_incomplete_and_unexpected_archive_contents_are_rejected(self):
        release.verify_archive(self.archive())
        for options in [
            {"omit": "licenses/mpdecimal-COPYRIGHT.txt"},
            {"omit": "lib/lean/Decimal/Basic.olean"},
            {"extra": "lib/libmpdec.so.4"},
            {"extra": "lib/../../outside"},
        ]:
            with self.subTest(options=options), self.assertRaises(SystemExit):
                release.verify_archive(self.archive(**options))

    def test_dynamic_backend_is_rejected_on_every_platform(self):
        Path("prefix/lib").mkdir(parents=True)
        Path("prefix/lib/libmpdec.a").touch()
        Path(".lake/build/bin").mkdir(parents=True)
        Path(".lake/build/lib/lean").mkdir(parents=True)
        Path(".lake/build/lib/lean/decimal_Decimal_Basic.so").touch()
        for name in ["decimal", "decimalTests", "decimalOracle", "decimalBench"]:
            for suffix in ["", ".exe"]:
                Path(".lake/build/bin", name + suffix).touch()
        for platform, clean, dynamic in [
            ("linux", "(NEEDED) Shared library: [libc.so.6]",
             "(NEEDED) Shared library: [libmpdec.so.4]"),
            ("darwin", "module:\n\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0)",
             "module:\n\t@rpath/libmpdec.4.dylib (compatibility version 4.0.0)"),
            ("win32", "Import {\n  Name: KERNEL32.dll\n}",
             "Import {\n  Name: LIBMPDEC-4.DLL\n}"),
        ]:
            with self.subTest(platform=platform), patch.object(release.sys, "platform", platform):
                with patch.object(release, "run", return_value=clean):
                    release.verify_static_linkage()
                # Cover a dynamically linked shared module even when all executables are static.
                with patch.object(release, "run", side_effect=[clean] * 4 + [dynamic]):
                    with self.assertRaisesRegex(SystemExit, "Dynamic libmpdec dependency"):
                        release.verify_static_linkage()

    def release_archives(self):
        for target in ["x86_64-unknown-linux-gnu", "x86_64-apple-darwin",
                       "aarch64-apple-darwin", "x86_64-w64-mingw32"]:
            path = self.archive(f"dist/decimal-{target}.tar.gz")
            Path(str(path) + ".sha256").write_text(
                f"{release.digest(path)}  {path.name}\n", encoding="utf-8")

    def test_checksum_failure_stops_before_tagging_or_publishing(self):
        self.release_archives()
        next(Path("dist").glob("*.sha256")).write_text("incorrect checksum\n", encoding="utf-8")
        with patch.object(release, "verify_ref", return_value=("v0.1.0", "revision", False)):
            with patch.object(release, "run") as command:
                with self.assertRaisesRegex(SystemExit, "Checksum mismatch"):
                    release.publish()
                command.assert_not_called()

    def test_publish_and_retry_upload_all_verified_assets(self):
        self.release_archives()

        def command(*args):
            if args[:3] == ("gh", "release", "view"):
                paths = [*Path("dist").glob("*.tar.gz"), Path("dist/SHA256SUMS")]
                return json.dumps({"assets": [
                    {"name": p.name, "size": p.stat().st_size,
                     "url": f"https://example.invalid/{p.name}"} for p in paths]})
            return ""

        for exists, verb in [(False, "create"), (True, "upload")]:
            with self.subTest(exists=exists):
                with patch.object(release, "verify_ref", return_value=("v0.1.0", "revision", exists)), \
                     patch.object(release, "run", side_effect=command) as run, \
                     patch.object(release.subprocess, "run", return_value=subprocess.CompletedProcess(
                         [], 0 if exists else 1)):
                    release.publish()
                calls = [call.args for call in run.call_args_list]
                uploads = [args for args in calls if args[:3] == ("gh", "release", verb)]
                self.assertEqual(len(uploads), 1)
                self.assertEqual(sum(arg.endswith(".tar.gz") for arg in uploads[0]), 4)
                self.assertIn(str(Path("dist/SHA256SUMS")), uploads[0])
                self.assertEqual(any(args[:2] == ("git", "push") for args in calls), not exists)
                if exists:
                    self.assertIn("--clobber", uploads[0])


if __name__ == "__main__":
    unittest.main()
