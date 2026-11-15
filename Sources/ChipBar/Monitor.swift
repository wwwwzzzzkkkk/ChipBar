import AppKit
import Darwin
import SwiftUI
import Combine
import Dispatch
import ChipBarCore

enum MemoryPressureLevel: Equatable {
    case unknown, normal, warning, critical

    var title: String {
        switch self {
        case .unknown: return "读取中"
        case .normal: return "正常"
        case .warning: return "偏高"
        case .critical: return "紧张"
        }
    }
}

private final class WeakMemoryPressureSource {
    weak var value: (any DispatchSourceMemoryPressure)?
    init(_ value: any DispatchSourceMemoryPressure) { self.value = value }
}

/// The dashboard no longer displays network throughput, so opening it
/// must not activate the independent network poller when no menu item uses it.
enum NetworkSamplingPolicy {
    static func isActive(startsAutomatically: Bool, paused: Bool, sleeping: Bool,
                         menuItems: Set<MenuContent>) -> Bool {
        startsAutomatically && !paused && !sleeping && menuItems.contains(.network)
    }
}

@MainActor final class Monitor: ObservableObject {
    @Published private(set) var sample: Sample?
    // Chart history is updated before publishing each sample. Publishing the
    // whole array separately doubled dashboard invalidations on every tick.
    private(set) var history: [Sample] = []
    private(set) var powerChart = PowerChartSnapshot.empty
    @Published private(set) var status = "正在连接 macmon…"
    @Published private(set) var error: String?
    @Published private(set) var paused = false
    @Published private(set) var sleeping = false
    @Published private(set) var connected = false
    @Published private(set) var memoryPressure: MemoryPressureLevel = .unknown
    @Published var menuItems: Set<MenuContent> {
        didSet {
            UserDefaults.standard.set(menuItems.map(\.rawValue), forKey: "menuItems")
            let previouslyNeededDisk = oldValue.contains(.disk) || oldValue.contains(.externalDisk)
            if previouslyNeededDisk != needsMenuDisk { restartMenuDisk() }
            configureNetwork()
        }
    }
    // Disk rates are rendered by MenuRefreshDriver after acquisition; they do
    // not need to invalidate the complete glass dashboard at each poll.
    private(set) var menuDisk: DiskActivitySnapshot?
    private var menuDiskSampler: DiskActivitySampler?
    @Published private(set) var dashboardVisible = false
    private let startsAutomatically: Bool
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
    private var memoryPressureSource: (any DispatchSourceMemoryPressure)?
    let ssd: ExternalSSDMonitor
    let network: NetworkMonitor
    private var ssdSubscription: AnyCancellable?
    let hardware: String

    init(start: Bool = true, ssdDefaults: UserDefaults = .standard, initialSample: Sample? = nil) {
        startsAutomatically = start
        ssd = ExternalSSDMonitor(defaults: ssdDefaults, start: start)
        network = NetworkMonitor(start: false)
        menuItems = UserDefaults.standard.stringArray(forKey: "menuItems")
            .map { Set($0.compactMap(MenuContent.init(rawValue:))).subtracting([.externalDisk]) }
            ?? [.logo, .power]
        let saved = UserDefaults.standard.integer(forKey: "interval")
        interval = [1000, 2000, 5000, 10000].contains(saved) ? saved : 2000
        menuMetric = PowerMetric(rawValue: UserDefaults.standard.string(forKey: "menuMetric") ?? "") ?? .total
        customPath = UserDefaults.standard.string(forKey: "macmonPath") ?? ""
        hardware = Self.sysctlString("machdep.cpu.brand_string") ?? "未知芯片"
        sample = initialSample
        connected = initialSample != nil
        history = initialSample.map { [$0] } ?? []
        // The standalone screenshot/fixture path does not open MenuController.
        // Seed its chart here so the visual preview retains real power data.
        if initialSample != nil {
            powerChart = PowerChartSnapshot.build(history: history, intervalMillis: interval)
            status = "预览 · 已有真实采样"
        }
        memoryPressure = Self.currentSystemMemoryPressure() ?? .unknown
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sleeping = true; self?.configureNetwork(); self?.restartMenuDisk(); self?.stop(); self?.status = "睡眠期间暂停" }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.sleeping = false; self.configureNetwork(); self.restartMenuDisk(); self.restart()
            }
        })
        ssdSubscription = ssd.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        startMemoryPressureMonitoring()
        if start { restart(); restartMenuDisk(); configureNetwork() }
    }

    private func startMemoryPressureMonitoring() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: .all, queue: .main)
        let sourceReference = WeakMemoryPressureSource(source)
        source.setEventHandler { [weak self, sourceReference] in
            let events = sourceReference.value?.data ?? []
            MainActor.assumeIsolated {
                guard let self else { return }
                // Dispatch source data represents the transition that just happened. Prefer it to the kernel query, which can briefly lag behind a transition and leave the badge on the old color.
                self.memoryPressure = events.isEmpty
                    ? (Self.currentSystemMemoryPressure() ?? .unknown)
                    : Self.memoryPressureLevel(for: events)
            }
        }
        memoryPressureSource = source
        source.activate()
    }

    static func memoryPressureLevel(for events: DispatchSource.MemoryPressureEvent) -> MemoryPressureLevel {
        if events.contains(.critical) { return .critical }
        if events.contains(.warning) { return .warning }
        if events.contains(.normal) { return .normal }
        return .unknown
    }

    static func memoryPressureLevel(forSystemValue value: Int32) -> MemoryPressureLevel? {
        // The live sysctl value is exposed as the DISPATCH_MEMORYPRESSURE_*
        // bit values on supported macOS systems: NORMAL=1, WARN=2, CRITICAL=4.
        // XNU also documents ordinal levels 0...4; accept the non-conflicting
        // aliases 0 and 3. In particular, 1 must stay green: treating it as
        // ordinal Warning caused Activity Monitor and ChipBar to disagree.
        switch value {
        case 0, 1: return .normal
        case 2: return .warning
        case 3, 4: return .critical
        default: return nil
        }
    }

    private static func currentSystemMemoryPressure() -> MemoryPressureLevel? {
        // This kernel status key gives the initial level synchronously where
        // available. The public dispatch source below keeps it updated; if the
        // key is unavailable, the UI stays honest until its first event.
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0) == 0,
              size == MemoryLayout<Int32>.size else { return nil }
        return memoryPressureLevel(forSystemValue: value)
    }

    var menuReadouts: [MenuReadout] {
        var items: [MenuReadout] = []
        if menuItems.contains(.power) {
            items.append(MenuReadout("power-" + menuMetric.rawValue, powerMenuText.replacingOccurrences(of: " W", with: "W"),
                                     menuMetric == .total ? "POWER" : menuMetric.rawValue.uppercased() + " W"))
        }
        if menuItems.contains(.utilization) {
            for (name, value) in [("CPU", sample?.cpuUtilization), ("GPU", sample?.gpuUtilization)] {
                let text = connected ? value.map { String(format: "%.0f%%", $0) } ?? "—" : "—"
                items.append(MenuReadout(name, text, name))
            }
        }
        if menuItems.contains(.memory) {
            let value = connected ? sample?.memory?.usedPercent : nil
            items.append(MenuReadout("memory", value.map { String(format: "%.0f%%", $0) } ?? "—", "RAM"))
        }
        if menuItems.contains(.cpuTemperature) {
            let value = connected ? sample?.cpuTemperature : nil
            items.append(MenuReadout("cpu-temperature", value.map { String(format: "%.0f°C", $0) } ?? "—", "CPU TEMP"))
        }
        items.append(contentsOf: ssd.selectedTemperatureReadouts)
        if menuItems.contains(.fans) {
            let rpm = connected ? sample?.fans.map(\.rpm).max() : nil
            items.append(MenuReadout("fans", rpm.map { String(format: "%.0f", $0) } ?? "—", "RPM"))
        }
        if menuItems.contains(.network) {
            items.append(MenuReadout("network", "↓" + MenuReadout.rate(network.rate?.download),
                                     "↑" + MenuReadout.rate(network.rate?.upload), pairedValues: true))
        }
        if menuItems.contains(.disk) {
            let rates = diskMenuRates
            items.append(MenuReadout("disk", "R " + MenuReadout.rate(rates.read),
                                     "W " + MenuReadout.rate(rates.write), pairedValues: true))
        }

        return items
    }

    private var needsMenuDisk: Bool { menuItems.contains(.disk) }
    private var menuDiskMaximumAge: TimeInterval { max(6, Double(interval) / 1000 * 3) }

    private var diskMenuRates: (read: Double?, write: Double?) {
        menuDisk?.menuRates(maximumAge: menuDiskMaximumAge) ?? (nil, nil)
    }

    var menuText: String {
        var parts: [String] = []
        if menuItems.contains(.power) { parts.append(powerMenuText) }
        if menuItems.contains(.utilization) {
            func percent(_ value: Double?) -> String {
                guard connected, let value else { return "—" }
                return String(format: "%.0f%%", value)
            }
            parts.append("CPU \(percent(sample?.cpuUtilization)) GPU \(percent(sample?.gpuUtilization))")
        }
        if menuItems.contains(.memory) {
            parts.append("内存 \(connected ? sample?.memory.map { String(format: "%.0f%%", $0.usedPercent) } ?? "—" : "—")")
        }
        if menuItems.contains(.cpuTemperature) {
            parts.append("CPU \(connected ? sample?.cpuTemperature.map { String(format: "%.0f°C", $0) } ?? "—" : "—")")
        }
        if menuItems.contains(.fans) {
            let fans = connected ? sample?.fans ?? [] : []
            parts.append(fans.isEmpty ? "风扇 —" : fans.map { String(format: "%.0f", $0.rpm) }.joined(separator: "/") + " RPM")
        }
        if menuItems.contains(.network) {
            parts.append("↓\(NetworkRate.text(network.rate?.download)) ↑\(NetworkRate.text(network.rate?.upload))")
        }
        if menuItems.contains(.disk) {
            let rates = diskMenuRates
            parts.append("读\(NetworkRate.text(rates.read)) 写\(NetworkRate.text(rates.write))")
        }

        let temperature = ssd.menuSuffix
        if !temperature.isEmpty { parts.append(String(temperature.dropFirst(3))) }
        return parts.joined(separator: " · ")
    }

    private func restartMenuDisk() {
        menuDisk = nil
        menuDiskSampler = needsMenuDisk && !paused && !sleeping ? DiskActivitySampler() : nil
    }

    func setDashboardVisible(_ visible: Bool) {
        guard dashboardVisible != visible else { return }
        if visible {
            powerChart = PowerChartSnapshot.build(history: history, intervalMillis: interval)
        }
        dashboardVisible = visible
        configureNetwork()
    }

    private func configureNetwork() {
        // The home dashboard has no network widget. A panel open must not
        // activate route-table queries unless network speed is in the menu bar.
        network.setPaused(!NetworkSamplingPolicy.isActive(
            startsAutomatically: startsAutomatically, paused: paused,
            sleeping: sleeping, menuItems: menuItems))
    }

    /// One display clock gathers fast counters, then presents the latest complete frame.
    /// SMART readings retain their independent, slow 30-second acquisition cadence.
    func sampleMenuSources() async {
        guard !paused, !sleeping else { return }
        if menuItems.contains(.network) { network.sample() }
        if let sampler = menuDiskSampler {
            let next = await sampler.sampleAll()
            guard !Task.isCancelled, sampler === menuDiskSampler else { return }
            menuDisk = next
        }
    }

    var menuSnapshot: MenuSnapshot {
        let text = menuText
        return MenuSnapshot(readouts: menuReadouts, showsLogo: menuItems.contains(.logo),
                            tooltip: "ChipBar · \(hardware) · \(text)",
                            accessibilityLabel: "ChipBar \(menuMetric.title) \(text)")
    }

    private var powerMenuText: String {
        if paused || sleeping { return "暂停" }
        guard connected, let power = sample?.power(menuMetric) else { return "— W" }
        return String(format: "%.1f W", power)
    }

    func stop(forQuit: Bool = false) {
        if forQuit { ssd.shutdown(); network.setPaused(true); menuDiskSampler = nil; menuDisk = nil }
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
                // Prepare the chart only when visible. Publishing the sample
                // once, after history and chart are ready, coalesces the UI.
                self.history.append(sample)
                let cutoff = sample.date.addingTimeInterval(-600)
                self.history.removeAll { $0.date < cutoff }
                if self.history.count > 600 {
                    self.history.removeFirst(self.history.count - 600)
                }
                if self.dashboardVisible {
                    self.powerChart = PowerChartSnapshot.build(
                        history: self.history, intervalMillis: self.interval)
                }
                self.sample = sample
                WidgetTelemetryBridge.shared.publish(sample, history: self.history)
                self.lastReceived = Date()
                if !self.connected { self.connected = true }
                if self.error != nil { self.error = nil }
                self.failureCount = 0
                let status = "实时采样 · \(self.interval / 1000) 秒"
                if self.status != status { self.status = status }
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
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                if Date().timeIntervalSince(self.lastReceived ?? self.startedAt) > max(10, Double(self.interval) / 1000 * 4) {
                    self.fail("macmon 长时间没有返回有效数据。请检查硬件支持或重新选择程序。")
                }
            }
        }
        watchdog?.tolerance = 0.2
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
        configureNetwork()
        restartMenuDisk()
        ssd.setPaused(paused)
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
