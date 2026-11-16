#!/usr/bin/env python3
"""Re-runnable exact-asset migration of published ChipBar releases from macmon."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

SOURCE = "wwwwzzzzkkkk/macmon"
TARGET = "wwwwzzzzkkkk/ChipBar"
LATEST = "chipbar-v4.0.0"
NAMES = frozenset(("ChipBar-macOS-arm64.zip", "SHA256SUMS"))
TAG_RE = re.compile(r"^chipbar-v([1-3])\.(\d+)\.(\d+)$")


def run(argv, *, stdin=None, missing_ok=False):
    result = subprocess.run(argv, input=stdin, capture_output=True,
                            text=True, check=False)
    if result.returncode == 0:
        return result.stdout
    if missing_ok and ("HTTP 404" in result.stderr or
                       "Not Found" in result.stderr):
        return None
    raise RuntimeError(f"{' '.join(argv)}: {result.stderr[-1800:]}")


def api(path, *, method="GET", payload=None, missing_ok=False):
    args = ["gh", "api", path]
    if method != "GET":
        args += ["--method", method]
    if payload is not None:
        args += ["--input", "-"]
    output = run(args, stdin=json.dumps(payload) if payload is not None else None,
                 missing_ok=missing_ok)
    return json.loads(output) if output is not None else None


def select_releases(releases):
    """Never import upstream macmon or new v4 releases."""
    return sorted((r for r in releases
                   if TAG_RE.fullmatch(r.get("tag_name", "")) and not r.get("draft")),
                  key=lambda r: tuple(int(x) for x in
                      TAG_RE.fullmatch(r["tag_name"]).groups()), reverse=True)


def originals():
    releases = []
    page = 1
    while True:
        part = api(f"repos/{SOURCE}/releases?per_page=100&page={page}")
        if not isinstance(part, list):
            raise RuntimeError("GitHub returned an invalid source release list")
        releases += part
        if len(part) < 100:
            break
        page += 1
    result = select_releases(releases)
    if len(result) < 63:
        raise RuntimeError(f"Expected at least 63 historical releases, got {len(result)}")
    return result


def source_assets(release):
    assets = {a["name"]: a for a in release.get("assets", [])
              if a.get("name") in NAMES}
    if set(assets) != NAMES:
        raise RuntimeError(f"{release['tag_name']}: original ZIP/SHA256SUMS missing")
    for name, a in assets.items():
        if not re.fullmatch(r"sha256:[a-f0-9]{64}", a.get("digest") or ""):
            raise RuntimeError(f"{release['tag_name']}/{name}: no source digest")
    return assets


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return "sha256:" + h.hexdigest()


def missing_assets(tag, original, target_release):
    present = {a["name"]: a for a in target_release.get("assets", [])}
    for name, src in original.items():
        dest = present.get(name)
        if dest is not None and (dest.get("digest") != src["digest"] or
                                 dest.get("size") != src["size"]):
            raise RuntimeError(f"{tag}/{name}: target differs from original; stop")
    return sorted(NAMES - present.keys())


def historical_body(release):
    tag = release["tag_name"]
    return (
        "> **Historical ChipBar release (unaltered assets).**\n"
        "> Original publication (UTC): **"
        + str(release.get("published_at", "unknown")) + "**.\n"
        f"> [Original publication]({release['html_url']}) · "
        f"[Current v4 release](https://github.com/{TARGET}/releases/tag/{LATEST})\n\n"
        "---\n\n" + (release.get("body") or "_No original notes were supplied._")
    )


def import_one(release):
    tag = release["tag_name"]
    original = source_assets(release)
    dest = api(f"repos/{TARGET}/releases/tags/{tag}", missing_ok=True)
    if dest is not None and not missing_assets(tag, original, dest):
        print("EXISTS", tag, flush=True)
        return
    with tempfile.TemporaryDirectory(prefix="chipbar-release-import-") as tmp:
        files = Path(tmp)
        run(["gh", "release", "download", tag, "--repo", SOURCE, "--dir", str(files)])
        for name, asset in original.items():
            path = files / name
            if (not path.is_file() or path.stat().st_size != asset["size"]
                    or sha256(path) != asset["digest"]):
                raise RuntimeError(f"{tag}/{name}: original download checksum failed")
        if dest is None:
            dest = api(f"repos/{TARGET}/releases", method="POST", payload={
                "tag_name": tag,
                "name": release.get("name") or tag,
                "body": historical_body(release),
                "draft": False,
                "prerelease": bool(release.get("prerelease", False)),
                "make_latest": "false",
            })
        missing = missing_assets(tag, original, dest)
        if missing:
            run(["gh", "release", "upload", tag, "--repo", TARGET] +
                [str(files / name) for name in missing])
    for i in range(8):
        dest = api(f"repos/{TARGET}/releases/tags/{tag}")
        if not missing_assets(tag, original, dest):
            print("IMPORTED", tag, "2 assets, SHA256 verified", flush=True)
            return
        time.sleep(3)
    raise RuntimeError(f"{tag}: uploaded assets did not become available")


def check_one(release):
    original = source_assets(release)
    tag = release["tag_name"]
    dest = api(f"repos/{TARGET}/releases/tags/{tag}", missing_ok=True)
    if dest is None or missing_assets(tag, original, dest):
        raise RuntimeError(f"{tag}: missing historical Release or assets")
    if (release["html_url"] not in (dest.get("body") or "")
            or release["published_at"] not in (dest.get("body") or "")):
        raise RuntimeError(f"{tag}: original date or source not retained")
    return tag


def ensure_current_latest():
    actual = api(f"repos/{TARGET}/releases/latest")
    if actual["tag_name"] != LATEST:
        current = api(f"repos/{TARGET}/releases/tags/{LATEST}")
        api(f"repos/{TARGET}/releases/{current['id']}", method="PATCH",
            payload={"make_latest": "true"})
        actual = api(f"repos/{TARGET}/releases/latest")
    if actual["tag_name"] != LATEST:
        raise RuntimeError(f"Latest regressed to {actual['tag_name']}")
    print("Current latest still", LATEST, flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--major", type=int, choices=[1, 2, 3])
    parser.add_argument("--verify", action="store_true")
    args = parser.parse_args()
    releases = originals()
    if args.verify:
        with ThreadPoolExecutor(max_workers=6) as executor:
            tags = list(executor.map(check_one, releases))
        print(f"VERIFIED {len(tags)} original releases and {len(tags)*2} assets",
              flush=True)
        ensure_current_latest()
    elif args.major:
        selected = [r for r in releases if int(TAG_RE.fullmatch(
            r["tag_name"]).group(1)) == args.major]
        print(f"Importing {len(selected)} historical v{args.major}.x Releases",
              flush=True)
        for release in selected:
            import_one(release)
    else:
        parser.error("Specify --major 1/2/3 or --verify")


if __name__ == "__main__":
    try:
        main()
    except RuntimeError as e:
        sys.exit(str(e))
