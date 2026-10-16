#!/usr/bin/env python3
"""Keep the legacy tap on the immutable ChipBar release in the macmon fork."""
import json
from pathlib import Path
import re
import subprocess

REPO = "wwwwzzzzkkkk/macmon"
ROOT = Path(__file__).resolve().parents[1]


def api(path, raw=False):
    args = ["gh", "api", path]
    if raw:
        args += ["-H", "Accept: application/vnd.github.raw+json"]
    return subprocess.check_output(args, text=True)


def sync():
    release = json.loads(api(f"repos/{REPO}/releases/latest"))
    match = re.fullmatch(r"chipbar-v([0-9]+\.[0-9]+\.[0-9]+)", release["tag_name"])
    if not match or release["draft"] or release["prerelease"]:
        raise ValueError("Expected a stable ChipBar release")
    version = match[1]
    asset = next(a for a in release["assets"] if a["name"] == "ChipBar-macOS-arm64.zip" and a["state"] == "uploaded")
    digest = asset["digest"].removeprefix("sha256:")
    cask = api(f"repos/{REPO}/contents/Casks/chipbar.rb?ref=chipbar", raw=True)
    if f'  version "{version}"' not in cask:
        print("Release published; waiting for its canonical Cask update")
        return
    if not re.fullmatch(r"[a-f0-9]{64}", digest) or f'  sha256 "{digest}"' not in cask:
        raise ValueError("Release digest does not match canonical Cask")
    if f'https://github.com/{REPO}/releases/download/chipbar-v#{{version}}/' not in cask:
        raise ValueError("Unexpected download URL")
    destination = ROOT / "Casks/chipbar.rb"
    current = destination.read_text()
    previous = re.search(r'^  version "([0-9.]+)"$', current, re.MULTILINE)[1]
    if tuple(map(int, previous.split('.'))) > tuple(map(int, version.split('.'))):
        raise ValueError("Refusing a Homebrew downgrade")
    destination.write_text(cask)
    print(f"Homebrew compatibility Cask synchronized to {version}")


if __name__ == "__main__":
    sync()
