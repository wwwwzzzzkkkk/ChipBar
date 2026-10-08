import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch
import plistlib
import tempfile
import struct
import datetime

spec = importlib.util.spec_from_file_location("chipbar_version", Path(__file__).resolve().parents[2] / "scripts/version.py")
version = importlib.util.module_from_spec(spec)
spec.loader.exec_module(version)


class VersionTests(unittest.TestCase):
    def test_release_date_uses_singapore_calendar_after_local_midnight(self):
        instant = datetime.datetime(2026, 10, 8, 17, tzinfo=datetime.timezone.utc)
        with patch.dict(version.os.environ, {"CHIPBAR_RELEASE_TIMEZONE": "Asia/Singapore"}):
            self.assertEqual(version.release_date(instant), "2026-10-09")
    def test_stable_versions_and_apple_bundle_limits(self):
        self.assertEqual(version.version_tuple("1.2.3"), (1, 2, 3))
        for invalid in ["v1.0.0", "1.0", "1.0.0-beta", "01.0.0", "1.100.0", "1.0.100", "1.0.0\n"]:
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                version.version_tuple(invalid)

    def test_bumps_and_explicit_version(self):
        for requested, expected in [("patch", "1.2.4"), ("minor", "1.3.0"), ("major", "2.0.0"), ("1.5.2", "1.5.2")]:
            self.assertEqual(version.next_version("1.2.3", requested), expected)
        for invalid in ["1.2.3", "1.0.0", "nonsense"]:
            with self.assertRaises(ValueError): version.next_version("1.2.3", invalid)

    def test_changelog_preserves_previous_history(self):
        text = "# Log\n\n## [Unreleased]\n\n- A fix\n\n## [1.0.0] - 2026-10-08\n\n- Old\n"
        changed = version.release_changelog(text, "1.0.1", "2026-10-09")
        self.assertIn("## [Unreleased]\n\n## [1.0.1] - 2026-10-09\n\n- A fix", changed)
        self.assertTrue(changed.endswith("- Old\n"))
        with self.assertRaises(ValueError): version.release_changelog(changed, "1.0.1", "2026-10-09")

    def test_homebrew_is_monotonic_and_release_checksum_is_immutable(self):
        old = 'cask "chipbar" do\n  version "1.0.0"\n  sha256 "' + "a" * 64 + '"\nend\n'
        changed = version.update_cask(old, "1.0.1", "b" * 64)
        self.assertIn('version "1.0.1"', changed)
        self.assertEqual(version.update_cask(changed, "1.0.1", "b" * 64), changed)
        with self.assertRaises(ValueError): version.update_cask(changed, "1.0.0", "a" * 64)
        with self.assertRaises(ValueError): version.update_cask(changed, "1.0.1", "c" * 64)
        with self.assertRaises(ValueError): version.update_cask(old, "1.0.1", "bad")

    def test_dirty_worktree_stops_before_any_publish_changes(self):
        with patch.object(version, "run", return_value=" M README.md") as run:
            with self.assertRaises(ValueError): version.prepare("patch")
            run.assert_called_once_with("git", "status", "--porcelain", capture=True)

    def test_package_rejects_mismatched_app_version_or_build_number(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "VERSION").write_text("1.0.2\n")
            metadata = root / "dist/ChipBar.app/Contents/Info.plist"
            metadata.parent.mkdir(parents=True)
            for app_version, build_number in [("1.0.1", "1.0.2"), ("1.0.2", "1")]:
                with metadata.open("wb") as stream:
                    plistlib.dump({"CFBundleShortVersionString": app_version, "CFBundleVersion": build_number}, stream)
                with patch.object(version, "ROOT", root), patch.object(version, "run") as run:
                    with self.assertRaises(ValueError): version.package()
                    run.assert_not_called()
                self.assertFalse((root / "dist" / version.ASSET).exists())

    def test_icon_missing_corrupt_or_incomplete_blocks_packaging(self):
        with tempfile.TemporaryDirectory() as temp:
            app = Path(temp)
            metadata = {"CFBundleIconFile": "AppIcon.icns"}
            with self.assertRaises(ValueError): version.validate_icon(app, {})
            with self.assertRaises(ValueError): version.validate_icon(app, metadata)
            icon = app / "Contents/Resources/AppIcon.icns"
            icon.parent.mkdir(parents=True)
            for data in [b"not an icon", b"icns" + struct.pack(">I", 8),
                         b"icns" + struct.pack(">I", 16) + b"ic10" + struct.pack(">I", 100)]:
                icon.write_bytes(data)
                with self.assertRaises(ValueError): version.validate_icon(app, metadata)

    def test_icon_accepts_native_small_and_retina_representation_families(self):
        with tempfile.TemporaryDirectory() as temp:
            app = Path(temp)
            icon = app / "Contents/Resources/AppIcon.icns"
            icon.parent.mkdir(parents=True)
            for small in [(b"ic04", b"ic05"), (b"icp4", b"icp5"), (b"is32", b"s8mk", b"il32", b"l8mk")]:
                chunks = b"".join(kind + struct.pack(">I", 12) + b"test" for kind in (*small, b"ic07", b"ic08", b"ic09", b"ic10"))
                icon.write_bytes(b"icns" + struct.pack(">I", len(chunks) + 8) + chunks)
                version.validate_icon(app, {"CFBundleIconFile": "AppIcon.icns"})


if __name__ == "__main__": unittest.main()
