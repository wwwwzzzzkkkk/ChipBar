import importlib.util
import sys
import unittest
from pathlib import Path

scripts = Path(__file__).resolve().parents[2] / "scripts"
sys.path.insert(0, str(scripts))
spec = importlib.util.spec_from_file_location("chipbar_legacy_tags", scripts / "import_legacy_tags.py")
tags = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tags)


class HistoricalTagTests(unittest.TestCase):
    def test_peel_lightweight_and_annotated_tags(self):
        from unittest.mock import patch
        self.assertEqual(tags.peel_to_commit("c" * 40, "commit"), "c" * 40)
        with patch.object(tags, "api", return_value={
            "object": {"type": "commit", "sha": "b" * 40}
        }) as api:
            self.assertEqual(tags.peel_to_commit("a" * 40, "tag"), "b" * 40)
            api.assert_called_once_with(
                "repos/wwwwzzzzkkkk/macmon/git/tags/" + "a" * 40
            )

    def test_pointer_identifies_original_source_without_impersonation(self):
        text = tags.archive_readme("chipbar-v1.3.1", "a" * 40)
        self.assertIn("archive pointer, NOT the historical source code", text)
        self.assertIn("github.com/wwwwzzzzkkkk/macmon/tree/chipbar-v1.3.1", text)
        self.assertIn("a" * 40, text)
        self.assertIn("github.com/wwwwzzzzkkkk/ChipBar/releases/tag/chipbar-v1.3.1", text)
