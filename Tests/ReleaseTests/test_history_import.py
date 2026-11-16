import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "chipbar_legacy_import",
    Path(__file__).resolve().parents[2] / "scripts/import_legacy_releases.py"
)
migration = importlib.util.module_from_spec(spec)
spec.loader.exec_module(migration)


class MigrationTests(unittest.TestCase):
    def test_only_old_chipbar_publications_selected(self):
        entries = [
            {"tag_name": "chipbar-v2.0.0", "draft": False},
            {"tag_name": "chipbar-v3.6.6", "draft": False},
            {"tag_name": "chipbar-v3.6.5", "draft": True},
            {"tag_name": "chipbar-v4.0.0", "draft": False},
            {"tag_name": "v1.3.0", "draft": False},
            {"tag_name": "macmon-v2.0.0", "draft": False},
        ]
        tags = [r["tag_name"] for r in migration.select_releases(entries)]
        self.assertEqual(tags, ["chipbar-v3.6.6", "chipbar-v2.0.0"])

    def test_refuse_changed_binary_and_resume_partial_release(self):
        orig = {
            "ChipBar-macOS-arm64.zip": {"digest": "sha256:" + "a"*64, "size": 120},
            "SHA256SUMS": {"digest": "sha256:" + "b"*64, "size": 90},
        }
        partial = {"assets": [{"name": "ChipBar-macOS-arm64.zip", **orig["ChipBar-macOS-arm64.zip"]}]}
        self.assertEqual(migration.missing_assets("chipbar-v3.0.0", orig, partial),
                         ["SHA256SUMS"])
        complete = {"assets": [{"name": k, **v} for k, v in orig.items()]}
        self.assertEqual(migration.missing_assets("chipbar-v3.0.0", orig, complete), [])
        mismatch = {"assets": [{"name": "ChipBar-macOS-arm64.zip",
                                 "digest": "sha256:" + "c"*64, "size": 120}]}
        with self.assertRaisesRegex(RuntimeError, "differs from original"):
            migration.missing_assets("chipbar-v3.0.0", orig, mismatch)

    def test_original_release_notes_and_date_preserved(self):
        release = {
            "tag_name": "chipbar-v3.6.6",
            "published_at": "2026-11-14T18:29:01Z",
            "html_url": "https://github.com/wwwwzzzzkkkk/macmon/releases/tag/chipbar-v3.6.6",
            "body": "Original Chinese release notes",
        }
        text = migration.historical_body(release)
        for part in [release["published_at"], release["html_url"], release["body"],
                     "chipbar-v4.0.0"]:
            self.assertIn(part, text)
