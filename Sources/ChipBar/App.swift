import AppKit
import SwiftUI
import ChipBarCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var monitor: Monitor?
    func applicationWillTerminate(_ notification: Notification) { Self.monitor?.stop(forQuit: true) }
}

struct ChipBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var monitor: Monitor
    init() {
        let monitor = Monitor()
        AppDelegate.monitor = monitor
        _monitor = StateObject(wrappedValue: monitor)
    }
    var body: some Scene {
        MenuBarExtra {
            Dashboard(monitor: monitor).onAppear { AppDelegate.monitor = monitor }
        } label: {
            Label(monitor.menuText, systemImage: "bolt.fill")
        }.menuBarExtraStyle(.window)
    }
}

@main enum Launch {
    @MainActor static func main() {
        let args = CommandLine.arguments
        if args.contains("--diagnose") { diagnose(args); return }
        if let index = args.firstIndex(of: "--snapshot"), args.count > index + 1 {
            snapshot(path: args[index + 1], settings: args.contains("--settings"), light: args.contains("--light")); return
        }
        ChipBarApp.main()
    }

    /// Bounded live probe, using exactly the same streaming client and decoder as the UI.
    static func diagnose(_ args: [String]) {
        let index = args.firstIndex(of: "--macmon")
        let path = index.flatMap { args.count > $0 + 1 ? args[$0 + 1] : nil } ?? "/opt/homebrew/bin/macmon"
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var count = 0
        var failed = false
        let client = StreamClient(path: path, interval: 1000, onSample: { sample in
            lock.lock(); defer { lock.unlock() }
            count += 1
            print("sample=\(count) chip=\(sample.chip ?? "unknown") total=\(sample.total.map(String.init(describing:)) ?? "unavailable")W cpu=\(sample.cpu.map(String.init(describing:)) ?? "unavailable")W gpu=\(sample.gpu.map(String.init(describing:)) ?? "unavailable")W cpuTemp=\(sample.cpuTemperature.map(String.init(describing:)) ?? "unavailable")")
            if count == 4 { semaphore.signal() }
        }, onFailure: { message in
            lock.lock(); failed = true; lock.unlock()
            fputs(message + "\n", stderr)
            semaphore.signal()
        })
        do { try client.start() }
        catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
        let result = semaphore.wait(timeout: .now() + 15)
        client.stop(wait: true)
        lock.lock(); let success = !failed && count >= 4; lock.unlock()
        if result == .timedOut { fputs("15 秒内未收到四个有效样本。\n", stderr) }
        exit(success ? 0 : 1)
    }

    /// Native SwiftUI rendering with live data; used for visual QA without screen permissions.
    @MainActor static func snapshot(path: String, settings: Bool, light: Bool) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let monitor = Monitor()
        AppDelegate.monitor = monitor
        let content = NSHostingView(rootView: Dashboard(monitor: monitor, showSettings: settings)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, light ? .light : .dark))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 390, height: 650),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "ChipBar · 实时预览"
        window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        window.contentView = content
        window.center(); window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 7) {
            let size = content.fittingSize
            window.setContentSize(size)
            content.layoutSubtreeIfNeeded()
            guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { exit(1) }
            content.cacheDisplay(in: content.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
            do { try png.write(to: URL(fileURLWithPath: path)) }
            catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
            monitor.stop(forQuit: true)
            exit(monitor.sample == nil ? 1 : 0)
        }
        app.run()
    }
}
