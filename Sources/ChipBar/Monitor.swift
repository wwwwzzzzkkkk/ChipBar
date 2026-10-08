import AppKit
import SwiftUI
import ChipBarCore

@MainActor final class Monitor: ObservableObject {
    @Published private(set) var sample: Sample?
    @Published private(set) var history: [Sample] = []
    @Published private(set) var status = "正在连接 macmon…"
    @Published private(set) var error: String?
    @Published private(set) var paused = false
    @Published private(set) var sleeping = false
    @Published private(set) var connected = false
    @Published var interval: Int {
        didSet { UserDefaults.standard.set(interval, forKey: "interval"); restart() }
    }
    @Published var menuMetric: PowerMetric {
        didSet { UserDefaults.standard.set(menuMetric.rawValue, forKey: "menuMetric") }
    }
    @Published private(set) var executablePath = ""
    private var customPath: String
    private var client: StreamClient?
    private var generation = UUID()
    private var retry: Task<Void, Never>?
    private var watchdog: Timer?
    private var startedAt = Date()
    private var lastReceived: Date?
    private var failureCount = 0
    private var observers: [NSObjectProtocol] = []
    let hardware: String

    init(start: Bool = true) {
        let saved = UserDefaults.standard.integer(forKey: "interval")
        interval = [1000, 2000, 5000, 10000].contains(saved) ? saved : 2000
        menuMetric = PowerMetric(rawValue: UserDefaults.standard.string(forKey: "menuMetric") ?? "") ?? .total
        customPath = UserDefaults.standard.string(forKey: "macmonPath") ?? ""
        hardware = Self.sysctlString("machdep.cpu.brand_string") ?? "未知芯片"
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sleeping = true; self?.stop(); self?.status = "睡眠期间暂停" }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sleeping = false; self?.restart() }
        })
        if start { restart() }
    }

    var menuText: String {
        if paused || sleeping { return "暂停" }
        guard connected, let power = sample?.power(menuMetric) else { return "— W" }
        return String(format: "%.1f W", power)
    }

    func stop(forQuit: Bool = false) {
        generation = UUID()
        retry?.cancel(); retry = nil
        watchdog?.invalidate(); watchdog = nil
        client?.stop(wait: forQuit); client = nil
        connected = false
    }

    func restart() {
        stop()
        guard !paused, !sleeping else { return }
        error = nil
        status = "正在连接 macmon…"
        sample = nil
        lastReceived = nil
        startedAt = Date()
        guard let path = resolvePath() else {
            error = "找不到可执行的 macmon。请在设置中选择已安装的 macmon 文件。常见位置：/opt/homebrew/bin/macmon。"
            status = "需要设置 macmon 路径"
            return
        }
        executablePath = path
        let token = generation
        let next = StreamClient(path: path, interval: interval, onSample: { [weak self] sample in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.sample = sample
                self.lastReceived = Date()
                self.connected = true
                self.error = nil
                self.failureCount = 0
                self.status = "实时采样 · \(self.interval / 1000) 秒"
                self.history.append(sample)
                let cutoff = Date().addingTimeInterval(-600)
                self.history.removeAll { $0.date < cutoff }
                if self.history.count > 600 { self.history.removeFirst(self.history.count - 600) }
            }
        }, onFailure: { [weak self] message in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.fail(message)
            }
        })
        client = next
        do { try next.start() }
        catch { fail("无法启动 macmon：\(error.localizedDescription)"); return }
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                if Date().timeIntervalSince(self.lastReceived ?? self.startedAt) > max(10, Double(self.interval) / 1000 * 4) {
                    self.fail("macmon 长时间没有返回有效数据。请检查硬件支持或重新选择程序。")
                }
            }
        }
    }

    private func fail(_ message: String) {
        stop()
        error = message
        failureCount += 1
        let delay = min(60, 2 * Int(pow(2.0, Double(min(failureCount - 1, 5)))))
        status = "采样中断 · \(delay) 秒后重试"
        retry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.restart()
        }
    }

    func togglePause() {
        paused.toggle()
        if paused { stop(); status = "采样已暂停"; error = nil } else { restart() }
    }

    func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.title = "选择 macmon 可执行文件"
        panel.message = "通常位于 /opt/homebrew/bin/macmon，可按 ⌘⇧G 输入路径。"
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                error = "所选文件不能执行，请选择 macmon 程序。"
                return
            }
            customPath = url.path
            UserDefaults.standard.set(customPath, forKey: "macmonPath")
            restart()
        }
    }

    func useDefaultPath() {
        customPath = ""
        UserDefaults.standard.removeObject(forKey: "macmonPath")
        restart()
    }

    private func resolvePath() -> String? {
        #if arch(arm64)
        let candidates = customPath.isEmpty ? ["/opt/homebrew/bin/macmon", "/usr/local/bin/macmon"] : [customPath]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        #else
        return nil
        #endif
    }

    private static func sysctlString(_ key: String) -> String? {
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
