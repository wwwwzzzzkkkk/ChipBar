import Foundation
import WidgetKit

/// Registration is distinct from the widget timeline. A properly embedded
/// .appex still needs PlugInKit/chronod to discover it after installation.
/// This helper never uses sudo, kills system services, or changes another app.
enum ChipBarWidgetPluginDiagnostics {
    static let extensionID = "local.chipbar.monitor.widgets"
    static let extensionPoint = "com.apple.widgetkit-extension"

    static func extensionURL(appURL: URL) -> URL {
        appURL.appendingPathComponent("Contents/PlugIns/ChipBarWidgets.appex")
    }

    struct Result {
        let registered: Bool
        let detail: String
    }

    private static func pluginkit(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus,
                    String(data: data, encoding: .utf8) ?? "")
        } catch {
            return (-1, error.localizedDescription)
        }
    }

    static func check(appURL: URL) -> Result {
        let extensionURL = extensionURL(appURL: appURL)
        guard FileManager.default.fileExists(atPath: extensionURL.path) else {
            return Result(registered: false,
                          detail: "未找到 ChipBarWidgets.appex，请从 3.3.1 或更新的正式安装包重新安装。")
        }
        let query = pluginkit(["-m", "-p", extensionPoint, "-i", extensionID, "-vv"])
        let discovered = query.status == 0 && query.output.contains(extensionID)
        return Result(registered: discovered,
                      detail: discovered
                        ? "系统已识别 ChipBar 小组件。若列表未立即刷新，请关闭后重新打开小组件库。"
                        : "系统尚未识别扩展，或扩展被忽略。可点击「修复小组件注册」。")
    }

    static func repair(appURL: URL) -> Result {
        let url = extensionURL(appURL: appURL)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return check(appURL: appURL)
        }
        let registration = pluginkit(["-a", url.path])
        guard registration.status == 0 else {
            return Result(registered: false,
                          detail: "注册失败：\(registration.output.prefix(180))")
        }
        let election = pluginkit(["-e", "use", "-p", extensionPoint, "-i", extensionID])
        guard election.status == 0 else {
            return Result(registered: false,
                          detail: "启用扩展失败：\(election.output.prefix(180))")
        }
        return check(appURL: appURL)
    }
}

@MainActor final class ChipBarWidgetRegistrationModel: ObservableObject {
    static let shared = ChipBarWidgetRegistrationModel()

    @Published private(set) var checking = false
    @Published private(set) var status = "尚未检查小组件注册状态"
    @Published private(set) var registered = false

    private let versionKey = "chipbar.widgets.registration.attempted-version.v1"
    private init() {}

    func ensureOnFirstLaunch() {
        let bundle = Bundle.main
        // Do not register a test executable or a partially staged artifact.
        guard bundle.bundleURL.pathExtension == "app",
              FileManager.default.fileExists(
                atPath: ChipBarWidgetPluginDiagnostics.extensionURL(
                    appURL: bundle.bundleURL).path) else { return }
        let version = bundle.infoDictionary?["CFBundleVersion"] as? String ?? ""
        guard !version.isEmpty,
              UserDefaults.standard.string(forKey: versionKey) != version else { return }
        perform(repair: true, versionToRecord: version)
    }

    func check() { perform(repair: false) }
    func repair() { perform(repair: true) }

    private func perform(repair: Bool, versionToRecord: String? = nil) {
        guard !checking else { return }
        checking = true
        status = repair ? "正在向 macOS 注册小组件…" : "正在检查系统小组件…"
        let appURL = Bundle.main.bundleURL
        Task { [weak self] in
            let outcome = await Task.detached(priority: .utility) {
                repair ? ChipBarWidgetPluginDiagnostics.repair(appURL: appURL) :
                         ChipBarWidgetPluginDiagnostics.check(appURL: appURL)
            }.value
            guard let self else { return }
            self.registered = outcome.registered
            self.status = outcome.detail
            self.checking = false
            if outcome.registered {
                if let versionToRecord {
                    UserDefaults.standard.set(versionToRecord, forKey: self.versionKey)
                }
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
    }
}
