import Foundation
import Testing
@testable import ChipBar

struct ChipBarUpdaterTests {
    @Test func semanticVersionsAreComparedNumerically() {
        #expect(ChipBarVersion("2.1.9")! < ChipBarVersion("2.1.10")!)
        #expect(ChipBarVersion("2.9.0")! < ChipBarVersion("2.10.0")!)
        #expect(ChipBarVersion("3.0.0")! > ChipBarVersion("2.99.99")!)
        #expect(ChipBarVersion("2.1.0") == ChipBarVersion("2.1.0"))
        #expect(ChipBarVersion("v2.1.0") == nil)
        #expect(ChipBarVersion("2.1") == nil)
        #expect(ChipBarVersion("2.1.0-beta") == nil)
        #expect(ChipBarVersion("02.1.0") == nil)
    }

    @Test func releaseMustHaveMatchingTrustedAssets() throws {
        let data = """
        {
          "tag_name": "chipbar-v2.2.0",
          "draft": false,
          "prerelease": false,
          "assets": [
            {"name": "ChipBar-macOS-arm64.zip", "size": 2492000,
             "browser_download_url": "https://github.com/wwwwzzzzkkkk/macmon/releases/download/chipbar-v2.2.0/ChipBar-macOS-arm64.zip"},
            {"name": "SHA256SUMS", "size": 90,
             "browser_download_url": "https://github.com/wwwwzzzzkkkk/macmon/releases/download/chipbar-v2.2.0/SHA256SUMS"}
          ]
        }
        """.data(using: .utf8)!
        let release = try JSONDecoder().decode(ChipBarUpdateRelease.self, from: data)
        #expect(release.version == "2.2.0")
        #expect(release.asset(named: ChipBarUpdateRelease.archiveName)?.size == 2492000)
        #expect(release.asset(named: ChipBarUpdateRelease.checksumName) != nil)
    }

    @Test func replacementPreservesPreviousAppUntilRelaunch() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(
            "chipbar-updater-unit-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let installed = root.appendingPathComponent("ChipBar.app")
        let staged = root.appendingPathComponent("new/ChipBar.app")
        let backup = root.appendingPathComponent("Previous-ChipBar.app")
        try manager.createDirectory(at: installed, withIntermediateDirectories: true)
        try manager.createDirectory(at: staged, withIntermediateDirectories: true)
        try "old".write(to: installed.appendingPathComponent("build"), atomically: true, encoding: .utf8)
        try "new".write(to: staged.appendingPathComponent("build"), atomically: true, encoding: .utf8)

        try ChipBarUpdateHelper.swap(prepared: staged, installed: installed, backup: backup)
        #expect(try String(contentsOf: installed.appendingPathComponent("build"), encoding: .utf8) == "new")
        #expect(try String(contentsOf: backup.appendingPathComponent("build"), encoding: .utf8) == "old")
    }

    @Test func failedReplacementRestoresOriginalApp() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(
            "chipbar-rollback-unit-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let installed = root.appendingPathComponent("ChipBar.app")
        let missing = root.appendingPathComponent("missing/ChipBar.app")
        let backup = root.appendingPathComponent("Previous-ChipBar.app")
        try manager.createDirectory(at: installed, withIntermediateDirectories: true)
        try "old".write(to: installed.appendingPathComponent("build"), atomically: true, encoding: .utf8)

        #expect(throws: Error.self) {
            try ChipBarUpdateHelper.swap(prepared: missing, installed: installed, backup: backup)
        }
        #expect(try String(contentsOf: installed.appendingPathComponent("build"), encoding: .utf8) == "old")
        #expect(!manager.fileExists(atPath: backup.path))
    }

    @Test func checksumMustMatchExactlyNamedZip() {
        let digest = String(repeating: "a", count: 64)
        #expect(ChipBarUpdateRelease.archiveDigest(from:
            "\(digest)  ChipBar-macOS-arm64.zip\n") == digest)
        #expect(ChipBarUpdateRelease.archiveDigest(from:
            "\(digest)  different.zip\n") == nil)
        #expect(ChipBarUpdateRelease.archiveDigest(from:
            "1234  ChipBar-macOS-arm64.zip\n") == nil)
    }
}
