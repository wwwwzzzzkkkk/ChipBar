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

    def test_migrated_cask_uses_namespaced_tag_and_fork_download(self):
        old = ('cask "chipbar" do\n  version "1.1.3"\n  sha256 "' + 'a' * 64 +
               '"\n  url "https://github.com/wwwwzzzzkkkk/ChipBar/releases/download/v#{version}/ChipBar-macOS-arm64.zip"\n'
               '  homepage "https://github.com/wwwwzzzzkkkk/ChipBar"\nend\n')
        migrated = version.update_cask(old, '1.1.4', 'b' * 64)
        self.assertIn('macmon/releases/download/chipbar-v#{version}/ChipBar-macOS-arm64.zip', migrated)
        self.assertIn('homepage "https://github.com/wwwwzzzzkkkk/macmon"', migrated)
        self.assertEqual(version.update_cask(migrated, '1.1.4', 'b' * 64), migrated)

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

    def test_glass_widgets_use_real_snapshot_data_for_every_system_size(self):
        root = Path(__file__).resolve().parents[2]
        widget = (root / "Sources/ChipBarWidgets/ChipBarWidgets.swift").read_text()
        glass = (root / "Sources/ChipBarWidgets/GlassWidgetViews.swift").read_text()
        shared = (root / "Sources/ChipBarCore/ChipBarSnapshot.swift").read_text()
        publisher = (root / "Sources/ChipBar/WidgetTelemetryBridge.swift").read_text()
        for family in [".systemSmall", ".systemMedium", ".systemLarge"]:
            self.assertIn(family, widget)
        for component in ["RingView", "SparklineView", "CoreBarsView",
                          "UsageBar", "PillView", "IconChip"]:
            self.assertIn(f"struct {component}: View", glass)
        for metric in ["chipPower", "avgPower", "peakPower", "powerSeries",
                       "internalPower", "cpu", "gpu", "mem", "cores",
                       "fanRPM", "aneWatts", "volumes"]:
            self.assertIn(f"var {metric}:", shared)
        self.assertIn("ChipBarSnapshotStore.write(snapshot)", publisher)
        self.assertIn("ChipBarSnapshotStore.readForWidget()", widget)
        self.assertIn("CoreBarsView(values:", glass)
        self.assertIn("containerBackground(for: .widget)", glass)
        self.assertIn("widgetRenderingMode", glass)
        self.assertNotIn("TimelineView(", glass)
        self.assertNotIn("withAnimation(", glass)
        self.assertIn("SnapshotEntry(date: .now, snapshot: .preview", widget)

    def test_new_widget_kinds_preserve_all_legacy_kinds(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "Sources/ChipBarWidgets/ChipBarWidgets.swift").read_text()
        shared = (root / "Sources/ChipBarCore/ChipBarSnapshot.swift").read_text()
        self.assertIn('newOverviewKind = "ChipBar.Overview"', shared)
        self.assertIn('newStorageKind = "ChipBar.Storage"', shared)
        self.assertIn("ChipBarOverviewWidget()", source)
        self.assertIn("ChipBarStorageWidget()", source)
        for module in ["OldOverview", "OldPowerTrend", "OldCPU", "OldGPU",
                       "OldMemory", "OldCores", "OldFan", "OldANE", "OldStorage",
                       "OldPowerSupply", "OldApplications"]:
            self.assertIn(f"LegacyWidget<{module}>()", source)
        self.assertIn('"local.chipbar.telemetry.\\(Module.tile.rawValue)"', source)
        self.assertIn("case overview, powerTrend, cpu, gpu, memory, cpuCores", source)

    def test_core_sampler_independent_of_dashboard_and_refreshes_host_snapshot(self):
        root = Path(__file__).resolve().parents[2]
        bridge = (root / "Sources/ChipBar/WidgetTelemetryBridge.swift").read_text()
        widget = (root / "Sources/ChipBarWidgets/ChipBarWidgets.swift").read_text()
        self.assertIn("private let coreSampler = CPUCoreSampler()", bridge)
        self.assertIn("updateCoreReadingsIfNeeded(now: now)", bridge)
        self.assertIn("await self.coreSampler.read()", bridge)
        self.assertIn('values["coreUsage"]', bridge)
        self.assertNotIn("CPUCoreLoadModel.shared.values", bridge)
        self.assertIn("now.timeIntervalSince(lastWrite) < 15", bridge)
        self.assertIn(">= 120", bridge)
        self.assertIn("now.addingTimeInterval(5 * 60)", widget)
        self.assertIn("reloadTimelines(", bridge)
        self.assertIn("lastCoreAttempt", bridge)

    def test_storage_snapshots_refresh_without_opening_the_menu(self):
        root = Path(__file__).resolve().parents[2]
        bridge = (root / "Sources/ChipBar/WidgetTelemetryBridge.swift").read_text()
        self.assertIn("private let internalStorageSampler = InternalStorageSampler()", bridge)
        self.assertIn("private let diskSampler = DiskActivitySampler()", bridge)
        self.assertIn("updateStorageReadingsIfNeeded(now: now)", bridge)
        self.assertIn("await self.diskSampler.sampleAll(includeVolumes: true)", bridge)
        self.assertIn("ExternalStorageCapacityModel.displayRows(from: freshDisk)", bridge)
        self.assertIn("values.removeValue(forKey: key)", bridge)
        self.assertIn("lastStorageAttempt", bridge)

    def test_widget_refresh_is_automatic_and_removed_from_settings(self):
        root = Path(__file__).resolve().parents[2]
        dashboard = (root / "Sources/ChipBar/Dashboard.swift").read_text()
        telemetry = (root / "Sources/ChipBar/WidgetTelemetryBridge.swift").read_text()
        controller = (root / "Sources/ChipBar/MenuController.swift").read_text()
        self.assertNotIn("desktopWidgetSettings", dashboard)
        self.assertNotIn("ChipBarTileSettings(layout:", dashboard)
        self.assertNotIn("widgetRegistration.check()", dashboard)
        self.assertNotIn("widgetRegistration.repair()", dashboard)
        self.assertIn("menuSSDTemperatureChoice", dashboard)
        self.assertIn("WidgetCenter.shared.reloadAllTimelines()", telemetry)
        self.assertIn("WidgetTelemetryBridge.shared.publish(sample, history: self.history)",
                      (root / "Sources/ChipBar/Monitor.swift").read_text())
        self.assertIn("ChipBarWidgetRegistrationModel.shared.ensureOnFirstLaunch()", controller)

    def test_widget_descriptors_never_use_interpolated_descriptions(self):
        # The widget extension is queried before the gallery can list tiles.
        # LocalizedStringKey interpolation inside WidgetConfiguration.description
        # can fatalError during getAllDescriptors with Cocoa IPC code 4099.
        source = (Path(__file__).resolve().parents[2] /
                  "Sources/ChipBarWidgets/ChipBarWidgets.swift").read_text()
        import re
        lines = re.findall(r'^\s*\.description\([^\n]*', source, re.MULTILINE)
        self.assertGreaterEqual(len(lines), 3,
                                "All new and legacy configurations require descriptions")
        for line in lines:
            self.assertRegex(line, r'^\s*\.description\("[^"]*"\)')
            self.assertNotIn(chr(92) + "(", line, "No interpolation in WidgetKit description")
        self.assertIn("ChipBar.Overview", (Path(__file__).resolve().parents[2] /
                      "Sources/ChipBarCore/ChipBarSnapshot.swift").read_text())
        self.assertNotIn('.configurationDisplayName("ChipBar · ' + chr(92) + '(', source)

    def test_widget_extension_is_required_and_must_identify_widgetkit(self):
        with tempfile.TemporaryDirectory() as temp:
            app = Path(temp)
            widget = app / "Contents/PlugIns/ChipBarWidgets.appex"
            with self.assertRaises(ValueError):
                version.validate_widget(app, "3.3.0")
            executable = widget / "Contents/MacOS/ChipBarWidgets"
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b"widget-executable")
            plist_path = widget / "Contents/Info.plist"
            metadata = {
                "CFBundleIdentifier": "local.chipbar.monitor.widgets",
                "CFBundleVersion": "3.3.0",
                "NSExtension": {
                    "NSExtensionPointIdentifier": "com.apple.widgetkit-extension"
                }
            }
            with plist_path.open("wb") as stream:
                plistlib.dump(metadata, stream)
            version.validate_widget(app, "3.3.0")
            with self.assertRaises(ValueError):
                version.validate_widget(app, "3.2.4")
            metadata["NSExtension"]["NSExtensionPointIdentifier"] = "com.apple.unknown"
            with plist_path.open("wb") as stream:
                plistlib.dump(metadata, stream)
            with self.assertRaises(ValueError):
                version.validate_widget(app, "3.3.0")

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
