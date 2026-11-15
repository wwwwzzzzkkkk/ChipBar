import AppKit
import CryptoKit
import Foundation

/// Accept stable ChipBar versions only; GitHub tags use the chipbar-v prefix.
struct ChipBarVersion: Comparable, Equatable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ value: String) {
        let fields = value.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 3,
              fields.allSatisfy({ !$0.isEmpty && ($0 == "0" || $0.first != "0")
                  && $0.allSatisfy(\.isNumber) }),
              let major = Int(fields[0]), let minor = Int(fields[1]), let patch = Int(fields[2])
        else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

struct ChipBarUpdateRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let size: Int
        let browser_download_url: URL
    }

    let tag_name: String
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]

    static let repository = "wwwwzzzzkkkk/macmon"
    static let archiveName = "ChipBar-macOS-arm64.zip"
    static let checksumName = "SHA256SUMS"

    var version: String? {
        guard tag_name.hasPrefix("chipbar-v") else { return nil }
        let value = String(tag_name.dropFirst("chipbar-v".count))
        return ChipBarVersion(value) != nil ? value : nil
    }

    func asset(named name: String) -> Asset? {
        guard let version, !draft, !prerelease else { return nil }
        let expected = "https://github.com/\(Self.repository)/releases/download/chipbar-v\(version)/\(name)"
        return assets.first { $0.name == name && $0.browser_download_url.absoluteString == expected }
    }

    /// A checksum must identify exactly the downloadable ZIP, never a different file.
    static func archiveDigest(from manifest: String) -> String? {
        let rows = manifest.split(whereSeparator: \.isNewline)
        for row in rows {
            let parts = row.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 2, parts[1] == Substring(archiveName) else { continue }
            let digest = String(parts[0])
            if digest.count == 64 && digest.utf8.allSatisfy({
                (48...57).contains($0) || (97...102).contains($0)
            }) { return digest }
        }
        return nil
    }
}

enum ChipBarUpdateFailure: LocalizedError {
    case invalidRelease
    case invalidResponse
    case invalidPackage(String)
    case cannotReplace(String)

    var errorDescription: String? {
        switch self {
        case .invalidRelease: return "GitHub Release 缺少可信的版本或安装包信息。"
        case .invalidResponse: return "检查更新失败：下载服务未返回有效内容。"
        case .invalidPackage(let detail): return "安装包校验失败：\(detail)"
        case .cannotReplace(let detail): return "无法自动替换当前应用：\(detail)"
        }
    }
}

private struct PreparedChipBarUpdate {
    let directory: URL
    let application: URL
}

/// Staging and cryptographic verification run off the main thread; no privileged
/// commands or shell scripts are used to replace the installed application.
private enum ChipBarUpdateInstaller {
    static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let explanation = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(),
                                     as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ChipBarUpdateFailure.invalidPackage(
                explanation.isEmpty ? "验证命令失败（\(process.terminationStatus)）" : explanation)
        }
    }

    static func prepare(archive: URL, expectedDigest: String, version: String,
                        currentApplication: URL) throws -> PreparedChipBarUpdate {
        let manager = FileManager.default
        let target = currentApplication.standardizedFileURL
        let parent = target.deletingLastPathComponent()
        guard target.pathExtension == "app", target.lastPathComponent == "ChipBar.app",
              !target.path.contains("/AppTranslocation/"),
              !target.path.contains("/Caskroom/"),
              !target.path.contains("/Cellar/"),
              manager.fileExists(atPath: target.path),
              manager.isWritableFile(atPath: parent.path)
        else {
            throw ChipBarUpdateFailure.cannotReplace(
                "请将 ChipBar.app 移到有写入权限的“应用程序”文件夹；Homebrew 安装请使用 brew upgrade --cask chipbar。")
        }
        let properties = try target.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard properties.isSymbolicLink != true else {
            throw ChipBarUpdateFailure.cannotReplace(
                "当前应用是符号链接。请通过 Homebrew 或安装管理器更新。")
        }

        let data = try Data(contentsOf: archive, options: .mappedIfSafe)
        guard data.count > 0 && data.count <= 100_000_000 else {
            throw ChipBarUpdateFailure.invalidPackage("文件大小异常")
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == expectedDigest else {
            throw ChipBarUpdateFailure.invalidPackage("SHA-256 与发布校验值不一致")
        }

        let root = parent.appendingPathComponent(".chipbar-update-\(UUID().uuidString)",
                                                  isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: false)
        do {
            let extracted = root.appendingPathComponent("extracted", isDirectory: true)
            try manager.createDirectory(at: extracted, withIntermediateDirectories: false)
            try run("/usr/bin/ditto", ["-x", "-k", "--noextattr", archive.path, extracted.path])
            let app = extracted.appendingPathComponent("ChipBar.app", isDirectory: true)
            let values = try app.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true && values.isSymbolicLink != true else {
                throw ChipBarUpdateFailure.invalidPackage("ZIP 中缺少 ChipBar.app")
            }
            let plistURL = app.appendingPathComponent("Contents/Info.plist")
            guard let info = NSDictionary(contentsOf: plistURL) as? [String: Any],
                  info["CFBundleIdentifier"] as? String == "local.chipbar.monitor",
                  info["CFBundleShortVersionString"] as? String == version,
                  info["CFBundleVersion"] as? String == version,
                  info["CFBundleExecutable"] as? String == "ChipBar"
            else { throw ChipBarUpdateFailure.invalidPackage("应用身份或版本不匹配") }

            try run("/usr/bin/codesign", ["--verify", "--strict", "--deep", app.path])
            return PreparedChipBarUpdate(directory: root, application: app)
        } catch {
            try? manager.removeItem(at: root)
            throw error
        }
    }
}

@MainActor final class ChipBarUpdater: ObservableObject {
    static let shared = ChipBarUpdater()
    @Published private(set) var status = "检查是否有可用的新版本。"
    @Published private(set) var availableVersion: String?
    @Published private(set) var busy = false

    private var release: ChipBarUpdateRelease?
    private var preparedDirectory: URL?

    init() {
        if let previous = ChipBarUpdateHelper.lastFailure(), !previous.isEmpty {
            status = "上次升级未完成：\(previous)"
        }
    }

    private var installedVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    func check() {
        guard !busy else { return }
        busy = true
        release = nil
        availableVersion = nil
        status = "正在检查 GitHub 更新…"
        Task {
            defer { busy = false }
            do {
                let endpoint = URL(string:
                    "https://api.github.com/repos/\(ChipBarUpdateRelease.repository)/releases/latest")!
                let data = try await Self.fetch(endpoint)
                let latest = try JSONDecoder().decode(ChipBarUpdateRelease.self, from: data)
                guard let newVersion = latest.version,
                      latest.asset(named: ChipBarUpdateRelease.archiveName) != nil,
                      latest.asset(named: ChipBarUpdateRelease.checksumName) != nil,
                      let remote = ChipBarVersion(newVersion),
                      let current = ChipBarVersion(installedVersion)
                else { throw ChipBarUpdateFailure.invalidRelease }
                if remote > current {
                    release = latest
                    availableVersion = newVersion
                    status = "发现新版本 \(newVersion)（当前 \(installedVersion)）。"
                } else {
                    status = "已是最新版本（\(installedVersion)）。"
                }
            } catch {
                status = "检查更新失败：\(error.localizedDescription)"
            }
        }
    }

    func install() {
        guard !busy, let release, let version = availableVersion,
              let archive = release.asset(named: ChipBarUpdateRelease.archiveName),
              let checksums = release.asset(named: ChipBarUpdateRelease.checksumName),
              archive.size > 0 && archive.size <= 100_000_000,
              checksums.size > 0 && checksums.size <= 100_000
        else { return }

        busy = true
        status = "正在下载并校验 ChipBar \(version)…"
        Task {
            do {
                let manifestData = try await Self.fetch(checksums.browser_download_url)
                guard manifestData.count <= 100_000,
                      let manifest = String(data: manifestData, encoding: .utf8),
                      let expectedDigest = ChipBarUpdateRelease.archiveDigest(from: manifest)
                else { throw ChipBarUpdateFailure.invalidPackage("缺少有效 SHA256SUMS") }

                let (zipData, response) = try await URLSession.shared.data(
                    from: archive.browser_download_url)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      zipData.count == archive.size, zipData.count <= 100_000_000
                else { throw ChipBarUpdateFailure.invalidResponse }
                let archiveURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("chipbar-download-\(UUID().uuidString).zip")
                try zipData.write(to: archiveURL, options: .atomic)
                defer { try? FileManager.default.removeItem(at: archiveURL) }
                status = "正在检查应用签名并准备安装…"
                let target = Bundle.main.bundleURL
                let prepared = try await Task.detached(priority: .userInitiated) {
                    try ChipBarUpdateInstaller.prepare(
                        archive: archiveURL, expectedDigest: expectedDigest,
                        version: version, currentApplication: target)
                }.value
                preparedDirectory = prepared.directory
                status = "正在替换旧版本并重新启动…"
                replaceAndRestart(prepared, version: version)
            } catch {
                busy = false
                status = "更新失败：\(error.localizedDescription)。原有版本未更改。"
            }
        }
    }

    private func replaceAndRestart(_ prepared: PreparedChipBarUpdate, version: String) {
        guard let executable = Bundle.main.executableURL else {
            busy = false
            status = "安装失败：无法找到当前应用的可执行文件。"
            try? FileManager.default.removeItem(at: prepared.directory)
            preparedDirectory = nil
            return
        }

        // Start a second process BEFORE quitting this instance. That helper
        // waits until the original app has fully terminated, then performs
        // the replace + relaunch. LaunchServices cannot mistakenly reuse the
        // still-running old app while it's being replaced.
        let worker = Process()
        worker.executableURL = executable
        worker.arguments = [
            ChipBarUpdateHelper.launchFlag,
            String(ProcessInfo.processInfo.processIdentifier),
            prepared.directory.path,
            Bundle.main.bundleURL.standardizedFileURL.path,
            version
        ]
        worker.standardInput = FileHandle.nullDevice
        worker.standardOutput = FileHandle.nullDevice
        worker.standardError = FileHandle.nullDevice
        do {
            try worker.run()
            status = "已校验安装包，正在退出旧版并安装 \(version)…"
            NSApplication.shared.terminate(nil)
        } catch {
            busy = false
            status = "无法启动安装辅助进程：\(error.localizedDescription)。旧版本未改变。"
            try? FileManager.default.removeItem(at: prepared.directory)
            preparedDirectory = nil
        }
    }

    private static func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ChipBarUpdateFailure.invalidResponse
        }
        return data
    }
}
