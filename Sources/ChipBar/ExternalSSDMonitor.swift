import AppKit
import Combine
import ChipBarCore

@MainActor final class ExternalSSDMonitor: ObservableObject {
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "ssdEnabled"); restart() } }
    @Published var showInMenu: Bool { didSet { defaults.set(showInMenu, forKey: "ssdMenu") } }
    @Published var useSudo: Bool { didSet { defaults.set(useSudo, forKey: "ssdSudo"); restart() } }
    @Published var deviceType: SMARTDeviceType { didSet { defaults.set(deviceType.rawValue, forKey: "ssdType"); restart() } }
    @Published private(set) var readings: [SSDReading] = []
    @Published private(set) var status = "外接 SSD 监控已关闭"
    @Published private(set) var executablePath = ""
    typealias Probe = @Sendable (String?, SMARTDeviceType, Bool, BoundedCommand) throws -> SSDProbeResult
    private let probe: Probe
    private let defaults: UserDefaults
    private var customPath: String
    private var worker: Task<Void, Never>?
    private var runner: BoundedCommand?
    private var generation = UUID()
    private var watchdog: Timer?
    private var observers: [NSObjectProtocol] = []
    private var paused = false
    private var sleeping = false
    private var stopped = false

    init(defaults: UserDefaults = .standard, start: Bool = true,
         probe: @escaping Probe = { path, type, sudo, command in
             try ExternalSSDProbe.read(path: path, type: type, useSudo: sudo) { try command.run($0, $1) }
         }) {
        self.probe = probe
        self.defaults = defaults
        enabled = defaults.bool(forKey: "ssdEnabled")
        showInMenu = defaults.bool(forKey: "ssdMenu")
        useSudo = defaults.bool(forKey: "ssdSudo")
        deviceType = SMARTDeviceType(rawValue: defaults.string(forKey: "ssdType") ?? "") ?? .auto
        customPath = defaults.string(forKey: "smartctlPath") ?? ""
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sleeping = true; self?.restart() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sleeping = false; self?.restart() }
        })
        for event in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(center.addObserver(forName: event, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.restart() }
            })
        }
        if start { restart() }
    }

    var menuSuffix: String {
        guard enabled, showInMenu else { return "" }
        let hottest = readings.compactMap { $0.temperature }.filter { $0.isFresh() }.compactMap(\.composite).max()
        return hottest.map { String(format: " · SSD %.0f°C", $0) } ?? " · SSD —"
    }

    func setPaused(_ paused: Bool) { self.paused = paused; restart() }

    func shutdown() {
        stopped = true
        cancel(wait: true)
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach { center.removeObserver($0) }; observers = []
    }

    private func cancel(wait: Bool = false) {
        generation = UUID()
        runner?.cancel(wait: wait); runner = nil
        worker?.cancel()
        watchdog?.invalidate(); watchdog = nil
        readings = []
    }

    func restart() {
        let previous = worker
        cancel()
        guard !stopped else { return }
        guard enabled else { status = "外接 SSD 监控已关闭"; return }
        guard !paused, !sleeping else { status = "SSD 读取已暂停"; return }
        let candidates = customPath.isEmpty ? ExternalSSDProbe.defaultPaths : [customPath]
        let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        executablePath = path ?? ""
        status = path == nil ? "未安装 smartctl，正在发现外接磁盘…" : "正在读取外接 SSD…"
        let token = generation, type = deviceType, sudo = useSudo && canUseSudo
        let command = BoundedCommand()
        let probe = self.probe
        runner = command
        worker = Task.detached(priority: .utility) { [weak self] in
            // A settings change cancels and drains the previous session before launching.
            await previous?.value
            while !Task.isCancelled {
                do {
                    let result = try probe(path, type, sudo, command)
                    await self?.receive(result, token: token)
                } catch {
                    if Task.isCancelled { return }
                    await self?.failed(error.localizedDescription, token: token)
                }
                do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
            }
        }
        watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.expire() }
        }
    }

    private func receive(_ result: SSDProbeResult, token: UUID) {
        guard generation == token else { return }
        readings = result.readings; status = result.status
        expire()
    }

    private func failed(_ message: String, token: UUID) {
        guard generation == token else { return }
        readings = []; status = message + " · 30 秒后重试"
    }

    private func expire() {
        guard readings.contains(where: { $0.temperature?.isFresh() == false }) else { return }
        readings = readings.map { row in
            var row = row
            if row.temperature?.isFresh() == false { row.temperature = nil; row.error = "温度数据已过期，等待重新读取。" }
            return row
        }
    }

    func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.title = "选择 smartctl 可执行文件"
        panel.message = "选择可信的 smartctl。启用非交互 sudo 后，仅允许自动找到的标准安装路径。"
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        if panel.runModal() == .OK, let url = panel.url, FileManager.default.isExecutableFile(atPath: url.path) {
            customPath = url.path; defaults.set(customPath, forKey: "smartctlPath"); useSudo = false; restart()
        }
    }

    func useDefaultPath() {
        customPath = ""; defaults.removeObject(forKey: "smartctlPath"); restart()
    }

    var canUseSudo: Bool { customPath.isEmpty }
}
