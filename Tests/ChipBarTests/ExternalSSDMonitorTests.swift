import Foundation
import Testing
import ChipBarCore
@testable import ChipBar

@MainActor struct ExternalSSDMonitorTests {
    func defaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: "chipbar-ssd-test-\(UUID().uuidString)")!
        defaults.set(true, forKey: "ssdEnabled")
        defaults.set(true, forKey: "ssdMenu")
        defaults.set("/usr/bin/true", forKey: "smartctlPath")
        return defaults
    }
    func result(date: Date = Date()) throws -> SSDProbeResult {
        let sample = try SSDTemperature.decode(Data(#"{"model_name":"Test NVMe","nvme_smart_health_information_log":{"temperature":44}}"#.utf8), date: date)
        return SSDProbeResult(readings: [SSDReading(id: "disk4", name: "Test NVMe", temperature: sample)], status: "test")
    }
    func awaitRead(_ monitor: ExternalSSDMonitor) async throws {
        for _ in 0..<100 {
            if !monitor.readings.isEmpty { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("SSD read did not finish")
    }

    @Test func temperatureMenuIsIndependentOfMacmonAndClearsOnPause() async throws {
        let output = try result()
        let monitor = ExternalSSDMonitor(defaults: defaults(), probe: { _, _, _, _ in output })
        defer { monitor.shutdown() }
        try await awaitRead(monitor)
        #expect(monitor.menuSuffix == " · SSD 44°C")
        monitor.showInMenu = false
        #expect(monitor.menuSuffix.isEmpty)
        #expect(monitor.menuTemperature == 44)
        monitor.showInMenu = true
        #expect(monitor.menuSuffix == " · SSD 44°C")
        monitor.setPaused(true)
        #expect(monitor.readings.isEmpty)
        #expect(monitor.menuSuffix == " · SSD —")
        monitor.setPaused(false)
        try await awaitRead(monitor)
        #expect(monitor.menuSuffix == " · SSD 44°C")
        monitor.enabled = false
        #expect(monitor.readings.isEmpty)
        #expect(monitor.menuSuffix.isEmpty)
    }

    @Test func cancelledReadCannotRepopulateDisabledMonitor() async throws {
        let output = try result()
        let monitor = ExternalSSDMonitor(defaults: defaults(), probe: { _, _, _, _ in
            Thread.sleep(forTimeInterval: 0.1)
            return output
        })
        defer { monitor.shutdown() }
        try await Task.sleep(nanoseconds: 30_000_000)
        monitor.enabled = false
        try await Task.sleep(nanoseconds: 180_000_000)
        #expect(monitor.readings.isEmpty)
        #expect(monitor.status == "外接 SSD 监控已关闭")
    }

    @Test func staleReadNeverReachesMenuAndShutdownClearsIt() async throws {
        let output = try result(date: Date().addingTimeInterval(-91))
        let monitor = ExternalSSDMonitor(defaults: defaults(), probe: { _, _, _, _ in output })
        try await awaitRead(monitor)
        #expect(monitor.readings.first?.temperature == nil)
        #expect(monitor.readings.first?.error?.contains("过期") == true)
        #expect(monitor.menuSuffix == " · SSD —")
        monitor.shutdown()
        #expect(monitor.readings.isEmpty)
    }

    @Test func selectingOneDriveDoesNotSelectUnrelatedDiskTemperature() async throws {
        let data = try SSDTemperature.decode(Data(#"{"model_name":"Sample NVMe","nvme_smart_health_information_log":{"temperature":50}}"#.utf8))
        let output = SSDProbeResult(readings: [
            SSDReading(id: "disk4", name: "Zark", temperature: data),
            SSDReading(id: "disk5", name: "Other", temperature: data)
        ], status: "test")
        let preferences = defaults()
        preferences.set(false, forKey: "ssdMenu")
        let monitor = ExternalSSDMonitor(defaults: preferences, probe: { _, _, _, _ in output })
        defer { monitor.shutdown() }
        try await awaitRead(monitor)
        monitor.setTemperatureInMenu(true, for: "disk4")
        #expect(monitor.showsTemperatureInMenu(for: "disk4"))
        #expect(!monitor.showsTemperatureInMenu(for: "disk5"))
        #expect(monitor.selectedTemperatureReadouts.count == 1)
        #expect(monitor.selectedTemperatureReadouts.first?.id == "ssd-disk4")
        #expect(preferences.stringArray(forKey: "ssdMenuDriveIDs") == ["disk4"])
        monitor.setTemperatureInMenu(false, for: "disk4")
        #expect(monitor.selectedTemperatureReadouts.isEmpty)
        #expect(!monitor.showsTemperatureInMenu(for: "disk4"))
    }

    @Test func unifiedMenuSSDChoiceEnablesRealLegacyReadout() {
        let preferences = defaults()
        preferences.set(false, forKey: "ssdMenu")
        preferences.set(false, forKey: "ssdMenuGlobalEnabled")
        let monitor = ExternalSSDMonitor(defaults: preferences, start: false,
            probe: { _, _, _, _ in SSDProbeResult(readings: [], status: "test") })
        defer { monitor.shutdown() }
        #expect(!monitor.showInMenu)
        #expect(!monitor.menuTemperaturesEnabled)
        monitor.setMenuTemperatureVisibility(true)
        #expect(monitor.showInMenu)
        #expect(monitor.menuTemperaturesEnabled)
        #expect(preferences.bool(forKey: "ssdMenuGlobalEnabled"))
        #expect(preferences.bool(forKey: "ssdMenu"))
        // As before, if no SSD is attached a permitted menu readout shows —.
        #expect(monitor.selectedTemperatureReadouts.first?.id == "ssd")
        monitor.setMenuTemperatureVisibility(false)
        #expect(!monitor.menuTemperaturesEnabled)
        #expect(monitor.selectedTemperatureReadouts.isEmpty)
        monitor.setMenuTemperatureVisibility(true)
        #expect(monitor.showInMenu)
        #expect(monitor.selectedTemperatureReadouts.first?.id == "ssd")
    }

    @Test func globalTemperatureVisibilityCanBeDisabledWithoutConnectedDisks() {
        let preferences = defaults()
        let monitor = ExternalSSDMonitor(defaults: preferences, start: false)
        defer { monitor.shutdown() }
        #expect(monitor.menuTemperaturesEnabled)
        #expect(monitor.readings.isEmpty)

        monitor.menuTemperaturesEnabled = false
        #expect(monitor.selectedTemperatureReadouts.isEmpty)
        #expect(monitor.menuSuffix.isEmpty)
        #expect(preferences.bool(forKey: "ssdMenuGlobalEnabled") == false)

        monitor.menuTemperaturesEnabled = true
        #expect(monitor.menuTemperaturesEnabled)
        #expect(preferences.bool(forKey: "ssdMenuGlobalEnabled"))
    }

    @Test func masterSwitchPreservesIndividualDrivePreferences() async throws {
        let result = try result()
        let preferences = defaults()
        let monitor = ExternalSSDMonitor(defaults: preferences, probe: { _, _, _, _ in result })
        defer { monitor.shutdown() }
        try await awaitRead(monitor)
        monitor.setTemperatureInMenu(true, for: "disk4")
        #expect(monitor.selectedTemperatureReadouts.count == 1)

        monitor.menuTemperaturesEnabled = false
        #expect(monitor.selectedTemperatureReadouts.isEmpty)
        #expect(monitor.menuSuffix.isEmpty)
        #expect(!monitor.showsTemperatureInMenu(for: "disk4"))
        monitor.menuTemperaturesEnabled = true
        #expect(monitor.showsTemperatureInMenu(for: "disk4"))
        #expect(monitor.selectedTemperatureReadouts.count == 1)
    }

    @Test func customExecutableCannotUseSudoEvenIfSavedPreferenceIsTrue() async throws {
        let saved = defaults()
        saved.set(true, forKey: "ssdSudo")
        let output = try result()
        let monitor = ExternalSSDMonitor(defaults: saved, probe: { path, _, sudo, _ in
            #expect(path == "/usr/bin/true")
            #expect(!sudo)
            return output
        })
        defer { monitor.shutdown() }
        try await awaitRead(monitor)
        #expect(!monitor.canUseSudo)
    }
}

