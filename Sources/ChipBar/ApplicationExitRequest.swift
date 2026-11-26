import AppKit

/// A ranking row aggregates processes. Resolve it to one registered app and
/// retain the launch identity until the user confirms the request.
@MainActor struct ApplicationExitTarget {
    let name: String
    private let pid: pid_t
    private let launchedAt: Date
    private let bundleURL: URL

    static func running(at path: String, named name: String) -> Self? {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let matches = NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && $0.activationPolicy != .prohibited &&
                $0.bundleURL?.resolvingSymlinksInPath() == url
        }
        guard matches.count == 1, let app = matches.first,
              app.processIdentifier > 0, app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let launchedAt = app.launchDate else { return nil }
        return Self(name: name, pid: app.processIdentifier, launchedAt: launchedAt, bundleURL: url)
    }

    func requestExit(force: Bool) -> String {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
              app.launchDate == launchedAt, app.bundleURL?.resolvingSymlinksInPath() == bundleURL else {
            return ChipBarLocale.choose("This app instance is no longer running.",
                                        "当时选中的应用实例已退出。")
        }
        let accepted = force ? app.forceTerminate() : app.terminate()
        if accepted {
            return force ? ChipBarLocale.choose("Force Quit request sent.", "已发送强制退出请求。")
                : ChipBarLocale.choose("Quit request sent. The app may ask you to save.",
                                       "已发送退出请求，应用可能会提示保存。")
        }
        return ChipBarLocale.choose("macOS did not accept the request.", "macOS 未接受退出请求。")
    }
}
