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


    @Test func laptopPowerFrameDoesNotEraseValidAdapterOrSystemWhenPackUnavailable() {
        let measured = ChipBarPowerSampler.laptopSystemFrame(
            onAdapter: true, adapterWatts: 44.7, batteryWatts: nil,
            measuredSystemWatts: 41.2)
        #expect(measured.systemWatts == 41.2)
        #expect(measured.systemSource == "PSTR")
        let unknown = ChipBarPowerSampler.laptopSystemFrame(
            onAdapter: true, adapterWatts: 44.7, batteryWatts: nil,
            measuredSystemWatts: nil)
        #expect(unknown.systemWatts == nil) // 44.7 adapter W is NOT system W

        let balanced = ChipBarPowerSampler.laptopSystemFrame(
            onAdapter: true, adapterWatts: 65, batteryWatts: 20,
            measuredSystemWatts: 43)
        #expect(balanced.systemWatts == 45)
        #expect(balanced.systemSource == "PDTR−battery")

        let battery = ChipBarPowerSampler.laptopSystemFrame(
            onAdapter: false, adapterWatts: nil, batteryWatts: -28,
            measuredSystemWatts: nil)
        #expect(battery.systemWatts == 28)
        let batteryMeasured = ChipBarPowerSampler.laptopSystemFrame(
            onAdapter: false, adapterWatts: nil, batteryWatts: nil,
            measuredSystemWatts: 25)
        #expect(batteryMeasured.systemWatts == 25)
    }

    @Test func macbookPartialDataAlwaysKeepsValidIndependentMeasurements() {
        let partial = ChipBarPowerReading(
            hasBattery: true, onAdapter: true, isCharging: true,
            batteryPercent: 60, adapterWatts: 44.7,
            batteryWatts: nil, systemWatts: nil,
            sourceLabel: "partial", live: true)
        #expect(LaptopPowerPresentation(reading: partial, chipWatts: 26.1)
                == .independent)
        #expect(LaptopPowerTopology(reading: partial, chipWatts: 26.1) == nil)

        var directSystem = partial
        directSystem.systemWatts = 40.0
        #expect(LaptopPowerPresentation(reading: directSystem, chipWatts: 26.1)
                == .systemAndChip)
        let split = PowerDistribution(internalWatts: directSystem.systemWatts,
                                      chipWatts: 26.1)
        #expect(abs((split.otherWatts ?? 0) - 13.9) < 0.001)

        directSystem.systemWatts = 19.0 // mismatched sampling, not a real split
        #expect(LaptopPowerPresentation(reading: directSystem, chipWatts: 26.1)
                == .independent)
        directSystem.systemWatts = nil
        directSystem.adapterWatts = nil
        #expect(LaptopPowerPresentation(reading: directSystem, chipWatts: nil)
                == .unavailable)
    }

    @Test func smcDecodesLegacyAdapterSp96() {
        #expect(SMCReader.decode(bytes: [0x0a, 0x80], type: "sp96") == 42.0)
        #expect(SMCReader.decode(bytes: [0xfd, 0x00], type: "sp96") == -12.0)
        #expect(SMCReader.decode(bytes: [0x2a, 0x00], type: "sp78") == 42.0)
        #expect(SMCReader.decode(bytes: [0x0a], type: "sp96") == nil)
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
        #expect(topology.hasBatteryTransfer)
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
        #expect(!battery.hasBatteryTransfer)

        let adapterOnly = ChipBarPowerReading(
            hasBattery: true, onAdapter: true, isCharging: false, batteryPercent: 80,
            adapterWatts: 32, batteryWatts: 0, systemWatts: 32,
            sourceLabel: "SMC", live: true)
        let adapter = try #require(LaptopPowerTopology(reading: adapterOnly, chipWatts: 12))
        #expect(adapter.mode == .adapter)
        #expect(adapter.chargeWatts == 0)
        #expect(!adapter.hasBatteryTransfer)

        let assisting = ChipBarPowerReading(
            hasBattery: true, onAdapter: true, isCharging: false, batteryPercent: 60,
            adapterWatts: 25, batteryWatts: -15, systemWatts: 40,
            sourceLabel: "SMC", live: true)
        let assisted = try #require(LaptopPowerTopology(reading: assisting, chipWatts: 18))
        #expect(assisted.mode == .adapterAssisted)
        #expect(assisted.sourceWatts == 25)
        #expect(assisted.assistWatts == 15)
        #expect(assisted.chargeWatts == 0)
        #expect(assisted.hasBatteryTransfer)
        #expect(assisted.sourceWatts + assisted.assistWatts == assisted.systemWatts)
        let chart = LaptopSankeyGeometry.make(assisted)
        #expect(abs(chart.systemHeight - chart.inputHeight - chart.assistHeight) < 0.001)
        #expect(chart.assistTop > chart.leftTop + chart.inputHeight)
    }

    @Test func batteryDirectPowerRailIsPreferredAndCurrentVoltageIsFallback() {
        let direct = ChipBarPowerSampler.selectBatteryPower(
            directWatts: 18.5, currentMilliAmps: 1000, voltageMilliVolts: 12000)
        #expect(direct?.watts == 18.5)
        #expect(direct?.source == "PPBR")

        let fallback = ChipBarPowerSampler.selectBatteryPower(
            directWatts: nil, currentMilliAmps: -1500, voltageMilliVolts: 12000)
        #expect(fallback?.watts == -18)
        #expect(fallback?.source == "B0AC/B0AV")

        let zeroDirect = ChipBarPowerSampler.selectBatteryPower(
            directWatts: 0, currentMilliAmps: 1000, voltageMilliVolts: 12000)
        #expect(zeroDirect?.watts == 12)
        #expect(zeroDirect?.source == "B0AC/B0AV")

        let zero = ChipBarPowerSampler.selectBatteryPower(
            directWatts: 0, currentMilliAmps: 0, voltageMilliVolts: 12000)
        #expect(zero?.watts == 0)

        let unknown = ChipBarPowerSampler.selectBatteryPower(
            directWatts: nil, currentMilliAmps: nil, voltageMilliVolts: nil)
        #expect(unknown?.watts == nil)
    }

    @Test func macbookZeroBatteryCurrentCollapsesToTwoStageAndPreservesStatus() throws {
        let pluggedNoCharge = ChipBarPowerReading(
            hasBattery: true, onAdapter: true, isCharging: false,
            batteryPercent: 75, adapterWatts: 23.7, batteryWatts: 0,
            systemWatts: 23.7, sourceLabel: "SMC", live: true)
        let flow = try #require(LaptopPowerTopology(
            reading: pluggedNoCharge, chipWatts: 7.8))
        #expect(flow.mode == .adapter)
        #expect(!flow.hasBatteryTransfer)
        #expect(flow.chargeWatts == 0)
        #expect(flow.systemWatts == 23.7)
        #expect(abs(flow.otherWatts - 15.9) < 0.001)
        #expect(flow.batteryPercent == 75)
        #expect(!flow.batteryCharged)

        var charged = pluggedNoCharge
        charged.isCharged = true
        let full = try #require(LaptopPowerTopology(reading: charged, chipWatts: 7.8))
        #expect(full.batteryCharged)
        #expect(!full.hasBatteryTransfer)
        // Mac mini's existing Sankey remains independent of the battery path.
        #expect(PowerSankeyGeometry.make(distribution:
            PowerDistribution(internalWatts: 23.7, chipWatts: 7.8)) != nil)
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
