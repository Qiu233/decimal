"""Keep project sources and documentation in English while allowing Lean notation."""

from pathlib import Path
import re
import subprocess


def main():
    paths = subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"]
    ).decode("utf-8").split("\0")
    han = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\U00020000-\U000323af]")
    failures = []
    for name in filter(None, paths):
        path = Path(name)
        if not path.is_file():
            continue
        if han.search(name):
            failures.append(f"{name}: file name contains Chinese text")
        try:
            content = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        for line, text in enumerate(content.splitlines(), 1):
            if han.search(text):
                failures.append(f"{name}:{line}: use English text")
    if failures:
        raise SystemExit("\n".join(failures))
    print("Project language check passed.")


if __name__ == "__main__":
    main()
