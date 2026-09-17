#!/usr/bin/env python3
"""Offline dependency, module API and missing-library tests; needs installed libmpdec."""
import argparse
import json
import shutil
import subprocess
import tempfile
from pathlib import Path


def run(args, cwd, *, success=True):
    result = subprocess.run(args, cwd=cwd, text=True, encoding="utf-8", capture_output=True)
    if (result.returncode == 0) != success:
        raise AssertionError(f"{args}\n{result.stdout}\n{result.stderr}")
    return result.stdout + result.stderr


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prefix", help="libmpdec installation prefix")
    parser.add_argument("--cc", help="host C compiler")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    with tempfile.TemporaryDirectory(prefix="lean decimal integration ") as tmp:
        tmp = Path(tmp)
        repo = tmp / "upstream"
        repo.mkdir()
        for name in ["Decimal", "Tests", "native"]:
            shutil.copytree(root / name, repo / name)
        for name in ["Decimal.lean", "Main.lean", "Bench.lean", "lakefile.lean", "lean-toolchain"]:
            shutil.copy2(root / name, repo / name)
        run(["git", "init", "--quiet"], repo)
        run(["git", "add", "."], repo)
        run(["git", "-c", "user.name=Decimal Test", "-c", "user.email=test@example.invalid",
             "commit", "--quiet", "-m", "Temporary test snapshot"], repo)
        rev = run(["git", "rev-parse", "HEAD"], repo).strip()
        consumer = tmp / "consumer"
        consumer.mkdir()
        config = "NameMap.empty"
        if args.prefix:
            config += " |>.insert `mpdecPrefix " + json.dumps(str(Path(args.prefix).resolve()))
        if args.cc:
            config += " |>.insert `mpdecCC " + json.dumps(args.cc)
        (consumer / "lakefile.lean").write_text(
            "module\npublic import Lake\npublic meta import Lake\n"
            "open Lake DSL\npublic section\npackage consumer\n"
            f"require decimal from git {json.dumps(repo.as_uri())} @ {json.dumps(rev)} with\n"
            f"  {config}\n"
            "lean_lib API\n"
            "@[default_target] lean_exe consumer where\n  root := `Main\n", encoding="utf-8")
        shutil.copy2(root / "lean-toolchain", consumer / "lean-toolchain")
        shutil.copy2(root / "tests" / "fixtures" / "ModuleAPI.lean", consumer / "API.lean")
        (consumer / "Main.lean").write_text(
            'module\nimport API\nmeta import API\n'
            'example := Decimal.ModuleTests.exact_tenths\n'
            '#eval Decimal.add {} (Decimal.parse "1.30").value (Decimal.parse "1.20").value\n'
            'public def main : IO Unit := do\n'
            '  let r := Decimal.add {} (Decimal.parse "0.1").value (Decimal.parse "0.2").value\n'
            '  unless r.value.toScientific == "0.3" && r.flags == 0 do\n'
            '    throw (IO.userError "incorrect FFI result")\n'
            '  IO.println "consumer passed"\n', encoding="utf-8")
        built = run(["lake", "build"], consumer)
        assert '"2.50"' in built, built
        assert "consumer passed" in run(["lake", "exe", "consumer"], consumer)
        # Real downstream imports must not see the native representation or proof helpers.
        for name in ["Decimal.mk", "Decimal.model",
                     "Decimal.Model.digits_count_eq", "Decimal.modelValue"]:
            (consumer / "Private.lean").write_text(
                f"module\nimport Decimal\n#check {name}\n", encoding="utf-8")
            diagnostic = run(["lake", "lean", "Private.lean"], consumer, success=False)
            assert "error" in diagnostic and name in diagnostic, diagnostic
        (consumer / "Private.lean").write_text(
            "module\nimport Decimal\n"
            "example (a : Decimal) : a.toModel = a.toModel := by\n"
            "  unfold Decimal.toModel\n  rfl\n", encoding="utf-8")
        diagnostic = run(["lake", "lean", "Private.lean"], consumer, success=False)
        assert "error" in diagnostic and "toModel" in diagnostic, diagnostic
        # Full file override makes this fail even on hosts that have a system libmpdec.
        missing = str(tmp / "missing" / "libmpdec.a")
        command = ["lake", "-R", f"-KmpdecLinkFile={missing}", "build"]
        if args.cc:
            command.insert(2, f"-KmpdecCC={args.cc}")
        diagnostic = run(command, repo, success=False)
        assert "decimal:" in diagnostic and "libmpdec" in diagnostic, diagnostic
        assert "Building Decimal" not in diagnostic, diagnostic
    print("Offline Git dependency, public re-exports, exposed definitions, kernel proofs, "
          "private boundaries, #eval, native linking, paths with spaces, and missing-library checks passed.")


if __name__ == "__main__":
    main()
