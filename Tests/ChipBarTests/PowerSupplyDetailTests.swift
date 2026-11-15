import Foundation
import Testing
@testable import ChipBar

struct PowerSupplyDetailTests {
    @Test func smcSamplingCadenceIsThreeSecondsAndSeparateFromMacmonInterval() {
        #expect(PowerSamplingCadence.seconds == 3)
        #expect(PowerSamplingCadence.nanoseconds == 3_000_000_000)
    }

    @Test func internalRailDifferenceIsCalculatedOnlyWhenValid() {
        let normal = PowerDistribution(internalWatts: 25, chipWatts: 16)
        #expect(normal.otherWatts == 9)
        #expect(normal.chipFraction == 0.64)
        #expect(normal.otherFraction == 0.36)
    }

    @Test func supplyModeAdaptsToMacMiniAndMacBookPowerState() {
        func reading(hasBattery: Bool, adapter: Bool, charging: Bool,
                     watts: Double?) -> ChipBarPowerReading {
            ChipBarPowerReading(hasBattery: hasBattery, onAdapter: adapter,
                                isCharging: charging, batteryPercent: 75,
                                adapterWatts: adapter ? 65 : nil,
                                batteryWatts: watts, systemWatts: 40,
                                sourceLabel: "test", live: true)
        }

        #expect(PowerSourceMode(reading: reading(hasBattery: false, adapter: true,
                                                 charging: false, watts: nil)) == .desktop)
        #expect(PowerSourceMode(reading: reading(hasBattery: true, adapter: false,
                                                 charging: false, watts: -31)) == .battery)
        #expect(PowerSourceMode(reading: reading(hasBattery: true, adapter: true,
                                                 charging: true, watts: 20)) == .adapterCharging)
        #expect(PowerSourceMode(reading: reading(hasBattery: true, adapter: true,
                                                 charging: false, watts: 0)) == .adapter)
        #expect(PowerSourceMode(reading: reading(hasBattery: true, adapter: true,
                                                 charging: false, watts: -5)) == .adapterAssisted)
        // The information tile was removed in v3.2.2; the side panel is compact.
        #expect(SidePanelLayout.height(for: .power) == 640)
        #expect(SidePanelLayout.width(for: .power) == 420)
        #expect(SidePanelLayout.contentWidth(for: .power) - 24 == 372)
        #expect(SidePanelLayout.width(for: .applications) == 314)
        #expect(SidePanelLayout.width(for: .externalDisk) == 314)
    }

    @Test func sankeyRibbonsMatchMeasuredWattsAndSixteenPointGap() throws {
        let distribution = PowerDistribution(internalWatts: 28.8, chipWatts: 6.4)
        let layout = try #require(PowerSankeyGeometry.make(distribution: distribution))
        #expect(abs(layout.totalHeight - 126.72) < 0.01)
        #expect(abs(layout.chipHeight - 28.16) < 0.01)
        #expect(abs(layout.otherHeight - 98.56) < 0.01)
        #expect(abs(layout.totalHeight - layout.chipHeight - layout.otherHeight) < 0.01)
        #expect(abs(layout.otherTop - layout.chipTop - layout.chipHeight - 16) < 0.01)
        #expect(layout.sourceTop >= 0)
        #expect(layout.otherTop + layout.otherHeight <= 190)
    }

    @Test func sankeyScaleCapsAtOneHundredFiftyPoints() throws {
        let distribution = PowerDistribution(internalWatts: 200, chipWatts: 50)
        let layout = try #require(PowerSankeyGeometry.make(distribution: distribution))
        #expect(abs(layout.totalHeight - 150) < 0.001)
        #expect(abs(layout.chipHeight - 37.5) < 0.001)
        #expect(abs(layout.otherHeight - 112.5) < 0.001)
        #expect(layout.otherTop + layout.otherHeight <= 190)
    }

    @Test func sankeyDoesNotDrawMissingOrImpossibleMeasurements() {
        #expect(PowerSankeyGeometry.make(distribution:
            PowerDistribution(internalWatts: nil, chipWatts: 6)) == nil)
        #expect(PowerSankeyGeometry.make(distribution:
            PowerDistribution(internalWatts: 20, chipWatts: nil)) == nil)
        #expect(PowerSankeyGeometry.make(distribution:
            PowerDistribution(internalWatts: 20, chipWatts: 25)) == nil)
        #expect(PowerSankeyGeometry.make(distribution:
            PowerDistribution(internalWatts: -1, chipWatts: 0)) == nil)
    }

    @Test func missingOrContradictoryReadingsAreNotFaked() {
        let missing = PowerDistribution(internalWatts: nil, chipWatts: 16)
        #expect(missing.otherWatts == nil)
        #expect(missing.chipFraction == nil)
        let contradiction = PowerDistribution(internalWatts: 12, chipWatts: 20)
        #expect(contradiction.otherWatts == nil)
        #expect(contradiction.chipFraction == nil)
        let negative = PowerDistribution(internalWatts: -5, chipWatts: 2)
        #expect(negative.otherWatts == nil)
    }
}
