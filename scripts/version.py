#!/usr/bin/env python3
"""One source for stable versions, release notes and Homebrew metadata."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
REPO = "wwwwzzzzkkkk/ChipBar"
ASSET = "ChipBar-macOS-arm64.zip"


def version_tuple(value):
    if not re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", value):
        raise ValueError("版本必须是 X.Y.Z，例如 1.0.1；不接受 v 前缀或预发布版本。")
    parts = tuple(map(int, value.split(".")))
    if parts[0] > 9999 or parts[1] > 99 or parts[2] > 99:
        raise ValueError("版本超出 Apple CFBundleVersion 的数字范围。")
    return parts


def current_version():
    value = (ROOT / "VERSION").read_text().strip()
    version_tuple(value)
    return value


def declared_tag():
    # Do not override GitHub's reserved GITHUB_* environment variables.
    return os.environ.get("CHIPBAR_RELEASE_TAG") or os.environ.get("GITHUB_REF", "").removeprefix("refs/tags/")


def next_version(current, requested):
    major, minor, patch = version_tuple(current)
    choices = {"patch": f"{major}.{minor}.{patch + 1}",
               "minor": f"{major}.{minor + 1}.0", "major": f"{major + 1}.0.0"}
    value = choices.get(requested, requested)
    if version_tuple(value) <= version_tuple(current):
        raise ValueError(f"新版本 {value} 必须大于当前版本 {current}。")
    return value


def release_changelog(text, version, date):
    marker = "## [Unreleased]\n"
    if marker not in text or f"## [{version}]" in text:
        raise ValueError("CHANGELOG 必须包含唯一的新版本与 Unreleased 区域。")
    before, body = text.split(marker, 1)
    boundary = re.search(r"^## \[", body, re.MULTILINE)
    pending = body[:boundary.start()] if boundary else body
    older = body[boundary.start():] if boundary else ""
    notes = pending.strip() or "- 维护更新；具体提交记录见 GitHub Release。"
    return f"{before}{marker}\n## [{version}] - {date}\n\n{notes}\n\n{older}"


def update_cask(text, version, digest):
    version_tuple(version)
    if not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise ValueError("校验值必须是 SHA-256。")
    match = re.search(r'^  version "([^"]+)"$', text, re.MULTILINE)
    if not match:
        raise ValueError("Cask 中没有唯一版本字段。")
    old = match.group(1)
    if version_tuple(old) > version_tuple(version):
        raise ValueError(f"拒绝把 Homebrew 从 {old} 降级到 {version}。")
    if old == version:
        checksum = re.search(r'^  sha256 "([^"]+)"$', text, re.MULTILINE)
        if not checksum or checksum.group(1) != digest:
            raise ValueError("同一已发布版本的校验值不可变，请发布新版本。")
        return text
    text, versions = re.subn(r'^  version "[^"]+"$', f'  version "{version}"', text, flags=re.MULTILINE)
    text, checksums = re.subn(r'^  sha256 "[^"]+"$', f'  sha256 "{digest}"', text, flags=re.MULTILINE)
    if versions != 1 or checksums != 1:
        raise ValueError("Cask 必须只有一个版本和一个校验值。")
    return text


def run(*args, capture=False):
    result = subprocess.run(args, cwd=ROOT, text=True, check=True,
                            stdout=subprocess.PIPE if capture else None)
    return result.stdout.strip() if capture else None


def prepare(requested):
    # Publish committed changes only, preserving unrelated work and existing tags.
    if run("git", "status", "--porcelain", capture=True):
        raise ValueError("请先提交工作区的修改，再发版。")
    if run("git", "branch", "--show-current", capture=True) != "main":
        raise ValueError("请在 main 分支发版。")
    remote = run("git", "remote", "get-url", "origin", capture=True)
    if remote not in (f"https://github.com/{REPO}.git", f"git@github.com:{REPO}.git"):
        raise ValueError("origin 不是 ChipBar 发布仓库。")
    run("git", "fetch", "origin", "main", "--tags")
    if run("git", "rev-parse", "HEAD", capture=True) != run("git", "rev-parse", "origin/main", capture=True):
        raise ValueError("请先同步并上传 main 分支，再发版。")
    version = next_version(current_version(), requested)
    tag = f"v{version}"
    if subprocess.run(["git", "show-ref", "--verify", "--quiet", f"refs/tags/{tag}"], cwd=ROOT).returncode == 0:
        raise ValueError(f"标签 {tag} 已存在；不可覆盖旧版本。")
    log = ROOT / "CHANGELOG.md"
    changed = release_changelog(log.read_text(), version, datetime.datetime.now(datetime.timezone.utc).date().isoformat())
    (ROOT / "VERSION").write_text(version + "\n")
    log.write_text(changed)
    run("git", "add", "VERSION", "CHANGELOG.md")
    run("git", "commit", "-m", f"Release {tag}")
    run("git", "tag", "-a", tag, "-m", f"ChipBar {version}")
    # Both refs move together or neither does; never force-update published refs.
    run("git", "push", "--atomic", "origin", "main", tag)
    print(f"已提交 {tag}。GitHub Actions 将测试、打包、发布并更新 Homebrew。")


def package():
    version = current_version()
    app = ROOT / "dist/ChipBar.app"
    with (app / "Contents/Info.plist").open("rb") as stream:
        metadata = plistlib.load(stream)
    if metadata.get("CFBundleShortVersionString") != version or metadata.get("CFBundleVersion") != version:
        raise ValueError("应用版本与 VERSION 不一致，请重新构建。")
    path = ROOT / "dist" / ASSET
    # Preserve executable mode but omit Finder/File Provider metadata from the ZIP.
    with tempfile.TemporaryDirectory(prefix="chipbar-package-") as staging:
        archive = Path(staging) / ASSET
        run("ditto", "-c", "-k", "--norsrc", "--noextattr", "--keepParent", str(app), str(archive))
        with zipfile.ZipFile(archive) as bundle:
            if bundle.testzip() is not None:
                raise ValueError("应用 ZIP 完整性检查失败。")
        extracted = Path(staging) / "verify"
        run("ditto", "-x", "-k", str(archive), str(extracted))
        run("codesign", "--verify", "--strict", str(extracted / "ChipBar.app"))
        path.write_bytes(archive.read_bytes())
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    (ROOT / "dist/SHA256SUMS").write_text(f"{digest}  {ASSET}\n")
    print(f"{path}\nSHA-256: {digest}")


def publish():
    version = current_version()
    tag = f"v{version}"
    if declared_tag() != tag:
        raise ValueError("仅在与 VERSION 一致的 GitHub 标签发布任务中执行 publish。")
    asset = ROOT / "dist" / ASSET
    existing = subprocess.run(["gh", "release", "view", tag, "--repo", REPO], capture_output=True)
    if existing.returncode != 0:
        text = (ROOT / "CHANGELOG.md").read_text()
        start = text.index(f"## [{version}]")
        next_heading = text.find("\n## [", start + 1)
        notes = text[start:next_heading if next_heading != -1 else len(text)]
        with tempfile.NamedTemporaryFile(mode="w", suffix=".md") as stream:
            stream.write(notes + "\n\nRequires Apple Silicon, macOS 13+ and separately installed macmon. "
                         "Locally signed; not notarized. M5 Pro sensors remain unverified.\n")
            stream.flush()
            run("gh", "release", "create", tag, str(asset), str(ROOT / "dist/SHA256SUMS"),
                "--repo", REPO, "--verify-tag", "--title", f"ChipBar {version}",
                "--notes-file", stream.name, "--generate-notes")
    # Retry uses the immutable remote asset, never replacing an existing Release ZIP.
    release = json.loads(run("gh", "api", f"repos/{REPO}/releases/tags/{tag}", capture=True))
    if release["draft"] or release["prerelease"]:
        raise ValueError("Homebrew 只跟随已发布的稳定版本。")
    assets = [a for a in release["assets"] if a["name"] == ASSET and a["state"] == "uploaded"]
    if len(assets) != 1:
        raise ValueError("Release 缺少唯一的已上传应用文件。")
    digest = assets[0].get("digest", "").removeprefix("sha256:")
    if not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise ValueError("GitHub 未返回 Release 文件 SHA-256，停止更新 Homebrew。")
    run("git", "fetch", "origin", "main")
    run("git", "checkout", "-B", "main", "origin/main")
    cask = ROOT / "Casks/chipbar.rb"
    old = cask.read_text()
    old_version = re.search(r'^  version "([^"]+)"$', old, re.MULTILINE).group(1)
    if version_tuple(old_version) > version_tuple(version):
        print("Homebrew 已指向更新的版本，保留现有配置。")
        return
    changed = update_cask(old, version, digest)
    if changed == old:
        print("Homebrew 已同步，无需再次提交。")
        return
    cask.write_text(changed)
    run("git", "add", "Casks/chipbar.rb")
    run("git", "commit", "-m", f"Update Homebrew cask to {tag}")
    run("git", "push", "origin", "main")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["show", "prepare", "package", "publish", "check-tag"])
    parser.add_argument("value", nargs="?")
    args = parser.parse_args()
    try:
        if args.command == "show": print(current_version())
        elif args.command == "prepare":
            if not args.value: raise ValueError("请提供 patch / minor / major 或明确版本。")
            prepare(args.value)
        elif args.command == "package": package()
        elif args.command == "publish": publish()
        elif args.command == "check-tag":
            if declared_tag() != f"v{current_version()}":
                raise ValueError("Git 标签与 VERSION 不一致。")
            tagged = run("git", "rev-parse", f"refs/tags/v{current_version()}^{{commit}}", capture=True)
            if tagged != run("git", "rev-parse", "HEAD", capture=True):
                raise ValueError("构建提交不属于声明的版本标签。")
    except (ValueError, subprocess.CalledProcessError, OSError) as error:
        sys.exit(str(error))


if __name__ == "__main__": main()
