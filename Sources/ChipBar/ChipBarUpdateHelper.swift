import AppKit
import Darwin
import Foundation

/// A detached copy of ChipBar's executable performs the replacement after the
/// original application exits. No shell command, password prompt or sudo is used.
enum ChipBarUpdateHelper {
    static let launchFlag = "--chipbar-apply-update"

    /// CLI: --chipbar-apply-update <old pid> <staging root> <installed app> <version>
    /// The helper's executable lives inside staging root, so the old application
    /// can exit before its on-disk bundle is changed.
    static func run(_ args: [String]) -> Int32 {
        guard args.count == 4, let oldPID = Int32(args[0]),
              oldPID > 0, ChipBarVersion(args[3]) != nil else { return 2 }
        let root = URL(fileURLWithPath: args[1], isDirectory: true).standardizedFileURL
        let installed = URL(fileURLWithPath: args[2], isDirectory: true).standardizedFileURL
        let staged = root.appendingPathComponent("extracted/ChipBar.app", isDirectory: true)
        let version = args[3]
        do {
            guard installed.lastPathComponent == "ChipBar.app",
                  installed.pathExtension == "app",
                  !installed.path.contains("/AppTranslocation/"),
                  !installed.path.contains("/Caskroom/"),
                  !installed.path.contains("/Cellar/"),
                  FileManager.default.isWritableFile(
                    atPath: installed.deletingLastPathComponent().path)
            else {
                throw ChipBarUpdateFailure.cannotReplace("安装目录不可写或由软件包管理器管理")
            }

            // Wait for the running executable to finish. Doing this in the
            // original ChipBar process could relaunch the old app instead.
            for _ in 0..<160 {
                if kill(oldPID, 0) != 0 && errno == ESRCH { break }
                Thread.sleep(forTimeInterval: 0.25)
            }
            guard kill(oldPID, 0) != 0 && errno == ESRCH else {
                throw ChipBarUpdateFailure.cannotReplace("旧版进程没有退出")
            }

            try validateApplication(staged, version: version)
            let backup = root.appendingPathComponent("Previous-ChipBar.app", isDirectory: true)
            try swap(prepared: staged, installed: installed, backup: backup)
            do {
                try launch(installed)
                // A successful open(1) only means LaunchServices accepted the
                // request. Confirm the intended new app is actually running.
                guard waitForLaunch(installed) else {
                    throw ChipBarUpdateFailure.cannotReplace("新版本未能启动")
                }
                try? FileManager.default.removeItem(at: backup)
                clearPreviousFailure()
                try? FileManager.default.removeItem(at: root)
                return 0
            } catch {
                let failed = root.appendingPathComponent("Failed-ChipBar.app")
                try? FileManager.default.moveItem(at: installed, to: failed)
                try FileManager.default.moveItem(at: backup, to: installed)
                try? launch(installed)
                Self.recordFailure("启动新版失败，已还原原版本：\(error.localizedDescription)")
                return 1
            }
        } catch {
            Self.recordFailure("自动安装失败：\(error.localizedDescription)")
            // If the old application was already closed, reopen it so an
            // installation error doesn't leave the user without a menu app.
            if FileManager.default.fileExists(atPath: installed.path) {
                try? launch(installed)
            }
            return 1
        }
    }

    static func validateApplication(_ application: URL, version: String) throws {
        let plist = application.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: plist) as? [String: Any],
              info["CFBundleIdentifier"] as? String == "local.chipbar.monitor",
              info["CFBundleShortVersionString"] as? String == version,
              info["CFBundleVersion"] as? String == version,
              info["CFBundleExecutable"] as? String == "ChipBar" else {
            throw ChipBarUpdateFailure.invalidPackage("待安装应用版本或标识不匹配")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--strict", "--deep", application.path]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ChipBarUpdateFailure.invalidPackage("安装前再次验证代码签名失败")
        }
    }

    /// Same-volume rename of already verified applications, with the old
    /// bundle retained as an undoable backup until LaunchServices succeeds.
    static func swap(prepared: URL, installed: URL, backup: URL) throws {
        let manager = FileManager.default
        try manager.moveItem(at: installed, to: backup)
        do {
            try manager.moveItem(at: prepared, to: installed)
        } catch {
            try manager.moveItem(at: backup, to: installed)
            throw error
        }
    }

    private static func launch(_ application: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", "-a", application.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ChipBarUpdateFailure.cannotReplace("LaunchServices 未接受新应用")
        }
    }

    private static func waitForLaunch(_ application: URL) -> Bool {
        for _ in 0..<32 {
            let running = NSRunningApplication.runningApplications(
                withBundleIdentifier: "local.chipbar.monitor")
            if running.contains(where: {
                !$0.isTerminated && $0.bundleURL?.standardizedFileURL == application.standardizedFileURL
            }) { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }

    private static var previousFailureURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ChipBar/last-update-error.txt")
    }

    private static func clearPreviousFailure() {
        try? FileManager.default.removeItem(at: previousFailureURL)
    }

    private static func recordFailure(_ reason: String) {
        let manager = FileManager.default
        try? manager.createDirectory(at: previousFailureURL.deletingLastPathComponent(),
                                     withIntermediateDirectories: true)
        let message = "\(Date()): \(reason)"
        try? message.write(to: previousFailureURL, atomically: true, encoding: .utf8)
    }

    static func lastFailure() -> String? {
        try? String(contentsOf: previousFailureURL, encoding: .utf8)
    }
}
