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


    @Test func laptopThreeStagePowerSeparatesBatteryChargeFromSystemAndChip() throws {
        let charging = ChipBarPowerReading(
            hasBattery: true, onAdapter: true, isCharging: true, batteryPercent: 65,
            adapterWatts: 65, batteryWatts: 20, systemWatts: 45,
            sourceLabel: "SMC", live: true)
        let topology = try #require(LaptopPowerTopology(reading: charging, chipWatts: 15))
        #expect(topology.mode == .adapterCharging)
        #expect(topology.sourceWatts == 65)
        #expect(topology.systemWatts == 45)
        #expect(topology.chargeWatts == 20)
        #expect(topology.assistWatts == 0)
        #expect(topology.otherWatts == 30)
        #expect(topology.sourceWatts == topology.systemWatts + topology.chargeWatts)

        let chart = LaptopSankeyGeometry.make(topology)
        #expect(chart.scale > 0)
        #expect(abs(chart.inputHeight - chart.systemHeight - chart.chargeHeight) < 0.001)
        #expect(abs(chart.systemHeight - chart.chipHeight - chart.otherHeight) < 0.001)
        #expect(abs(chart.chargeTop - chart.systemTop - chart.systemHeight -
                    LaptopSankeyGeometry.gap) < 0.001)
        #expect(chart.leftTop >= 0)
        #expect(chart.chargeTop + chart.chargeHeight <= LaptopSankeyGeometry.height)
        #expect(chart.otherTop + chart.otherHeight <= LaptopSankeyGeometry.height)
    }

    @Test func laptopThreeStageAdaptsToBatteryOnlyAdapterOnlyAndCombinedSupply() throws {
        let onBattery = ChipBarPowerReading(
            hasBattery: true, onAdapter: false, isCharging: false, batteryPercent: 40,
            adapterWatts: 0, batteryWatts: -25, systemWatts: 25,
            sourceLabel: "SMC", live: true)
        let battery = try #require(LaptopPowerTopology(reading: onBattery, chipWatts: 10))
        #expect(battery.mode == .battery)
        #expect(battery.sourceWatts == 25)
        #expect(battery.chargeWatts == 0)
        #expect(battery.otherWatts == 15)

        let adapterOnly = ChipBarPowerReading(
            hasBattery: true, onAdapter: true, isCharging: false, batteryPercent: 80,
            adapterWatts: 32, batteryWatts: 0, systemWatts: 32,
            sourceLabel: "SMC", live: true)
        let adapter = try #require(LaptopPowerTopology(reading: adapterOnly, chipWatts: 12))
        #expect(adapter.mode == .adapter)
        #expect(adapter.chargeWatts == 0)

        let assisting = ChipBarPowerReading(
            hasBattery: true, onAdapter: true, isCharging: false, batteryPercent: 60,
            adapterWatts: 25, batteryWatts: -15, systemWatts: 40,
            sourceLabel: "SMC", live: true)
        let assisted = try #require(LaptopPowerTopology(reading: assisting, chipWatts: 18))
        #expect(assisted.mode == .adapterAssisted)
        #expect(assisted.sourceWatts == 25)
        #expect(assisted.assistWatts == 15)
        #expect(assisted.chargeWatts == 0)
        #expect(assisted.sourceWatts + assisted.assistWatts == assisted.systemWatts)
        let chart = LaptopSankeyGeometry.make(assisted)
        #expect(abs(chart.systemHeight - chart.inputHeight - chart.assistHeight) < 0.001)
        #expect(chart.assistTop > chart.leftTop + chart.inputHeight)
    }

    @Test func laptopThreeStageRejectsMissingStaleAndContradictorySensorValues() {
        func reading(adapter: Double?, battery: Double?, system: Double?,
                     charging: Bool = true, live: Bool = true) -> ChipBarPowerReading {
            ChipBarPowerReading(
                hasBattery: true, onAdapter: true, isCharging: charging,
                batteryPercent: 70, adapterWatts: adapter, batteryWatts: battery,
                systemWatts: system, sourceLabel: "SMC", live: live)
        }
        #expect(LaptopPowerTopology(reading: reading(adapter: 65, battery: 20,
                                                     system: 45), chipWatts: 55) == nil)
        #expect(LaptopPowerTopology(reading: reading(adapter: 65, battery: 20,
                                                     system: 35), chipWatts: 15) == nil)
        #expect(LaptopPowerTopology(reading: reading(adapter: nil, battery: 20,
                                                     system: 45), chipWatts: 15) == nil)
        #expect(LaptopPowerTopology(reading: reading(adapter: 65, battery: nil,
                                                     system: 45), chipWatts: 15) == nil)
        #expect(LaptopPowerTopology(reading: reading(adapter: 65, battery: 20,
                                                     system: 45, charging: false), chipWatts: 15) == nil)
        #expect(LaptopPowerTopology(reading: reading(adapter: 65, battery: 20,
                                                     system: 45, live: false), chipWatts: 15) == nil)
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
