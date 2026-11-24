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

    @Test func macbookPartialDataDrawsOnlyIndependentlyValidatedSystemSplit() throws {
        var partial = ChipBarPowerReading(
            hasBattery: true, onAdapter: true, isCharging: true,
            batteryPercent: 60, adapterWatts: 44.7,
            batteryWatts: nil, systemWatts: nil,
            sourceLabel: "partial", live: true)
        #expect(PowerFlowTopology(reading: partial, chipWatts: 26.1) == nil)
        #expect(PowerFlowTopology(validatedSystemOf: partial, chipWatts: 26.1) == nil)

        partial.systemWatts = 40.0
        let split = try #require(PowerFlowTopology(validatedSystemOf: partial, chipWatts: 26.1))
        #expect(!split.showsSupply)
        #expect(split.hasBreakdown)
        #expect(split.chargeWatts == 0)
        #expect(abs(split.otherWatts - 13.9) < 0.001)

        partial.systemWatts = 19.0 // Mismatched sampling cannot form a split.
        #expect(PowerFlowTopology(validatedSystemOf: partial, chipWatts: 26.1) == nil)
    }

    @Test func smcDecodesLegacyAdapterSp96() {
        #expect(SMCReader.decode(bytes: [0x0a, 0x80], type: "sp96") == 42.0)
        #expect(SMCReader.decode(bytes: [0xfd, 0x00], type: "sp96") == -12.0)
        #expect(SMCReader.decode(bytes: [0x2a, 0x00], type: "sp78") == 42.0)
        #expect(SMCReader.decode(bytes: [0x0a], type: "sp96") == nil)
    }

    @Test func signedBatteryPowerKeyUsesMilliwattsAndPreservesDischargeDirection() {
        #expect(SMCReader.decode(bytes: [0x20, 0x4e, 0x00, 0x00], type: "si32") == 20000)
        #expect(SMCReader.decode(bytes: [0xe0, 0xb1, 0xff, 0xff], type: "si32") == -20000)
        #expect(SMCReader.decode(bytes: [0x20], type: "si32") == nil)
        let charge = ChipBarPowerSampler.selectBatteryPower(
            directWatts: nil, currentMilliAmps: nil, voltageMilliVolts: nil,
            directMilliWatts: 20000)
        #expect(charge?.watts == 20)
        #expect(charge?.source == "B0AP")
        let discharge = ChipBarPowerSampler.selectBatteryPower(
            directWatts: 0, currentMilliAmps: nil, voltageMilliVolts: nil,
            directMilliWatts: -20000)
        #expect(discharge?.watts == -20)
        let fallback = ChipBarPowerSampler.selectBatteryPower(
            directWatts: 18, currentMilliAmps: nil, voltageMilliVolts: nil,
            directMilliWatts: 0)
        #expect(fallback?.source == "PPBR")
        #expect(fallback?.watts == 18)
    }

    @Test func pluggedInM1ProRejectsPositivePPBRWhenSignedSensorsAgree() {
        // Live M1 Pro samples from the idle pack and low-power adapter.
        for sample in [
            (adapter: 28.688562393188477, system: 28.69367790222168,
             ppbr: 1.1022194623947144, b0ap: 0.0, current: 0.0, voltage: 11899.0),
            (adapter: 6.816970348358154, system: 7.205906391143799,
             ppbr: 1.5929789543151855, b0ap: -227.0, current: -19.0, voltage: 11967.0)
        ] {
            let pack = ChipBarPowerSampler.selectBatteryPower(
                directWatts: sample.ppbr, currentMilliAmps: sample.current,
                voltageMilliVolts: sample.voltage, directMilliWatts: sample.b0ap,
                pluggedInWithoutCharging: true)
            #expect(pack?.source == "B0AP")
            #expect(pack?.watts == sample.b0ap / 1_000)

            let frame = ChipBarPowerSampler.laptopSystemFrame(
                onAdapter: true, adapterWatts: sample.adapter, batteryWatts: pack?.watts,
                measuredSystemWatts: sample.system)
            #expect(frame.systemWatts == sample.adapter - sample.b0ap / 1_000)
        }
    }

    @Test func registryBatteryCurrentPreservesSignAndRejectsContradictions() {
        #expect(ChipBarPowerSampler.signedBatteryCurrent(NSNumber(value: -1500)) == -1500)
        #expect(ChipBarPowerSampler.signedBatteryCurrent(
            NSNumber(value: UInt32(bitPattern: -1500))) == -1500)
        #expect(ChipBarPowerSampler.signedBatteryCurrent(
            NSNumber(value: UInt64(bitPattern: -1500))) == -1500)
        #expect(ChipBarPowerSampler.batteryWatts(
            currentMilliAmps: -1500, voltageMilliVolts: 12000) == -18)
        #expect(ChipBarPowerSampler.registryPowerMatchesState(
            -18, onAdapter: false, charging: false))
        #expect(!ChipBarPowerSampler.registryPowerMatchesState(
            18, onAdapter: false, charging: false))
        #expect(!ChipBarPowerSampler.registryPowerMatchesState(
            -18, onAdapter: true, charging: true))
        #expect(ChipBarPowerSampler.registryPowerMatchesState(
            -18, onAdapter: true, charging: false))
    }

    @Test func cachedBatteryBalanceUsesIndependentSystemWhenReadingsDisagree() {
        let conflict = ChipBarPowerSampler.laptopSystemFrame(
            onAdapter: true, adapterWatts: 65, batteryWatts: 20,
            measuredSystemWatts: 24, batteryIsCached: true)
        #expect(conflict.systemSource == "PSTR")
        #expect(conflict.systemWatts == 24)
        let estimate = ChipBarPowerSampler.laptopSystemFrame(
            onAdapter: true, adapterWatts: 65, batteryWatts: 20,
            measuredSystemWatts: 44, batteryIsCached: true)
        #expect(estimate.systemWatts == 45)
        #expect(estimate.systemSource == "PDTR−battery (cached estimate)")
        var reading = ChipBarPowerReading(
            hasBattery: true, onAdapter: true, isCharging: true,
            batteryPercent: 65, adapterWatts: 45, batteryWatts: 0,
            systemWatts: 45, sourceLabel: "test", live: true)
        #expect(PowerFlowTopology(reading: reading, chipWatts: 16) == nil)
        reading.batteryWatts = 20
        reading.adapterWatts = 65
        reading.diagnostics.batterySource = "AppleSmartBattery (cached)"
        #expect(PowerFlowTopology(reading: reading, chipWatts: 16)?.batteryIsCached == true)
    }

    @Test func laptopThreeStagePowerSeparatesBatteryChargeFromSystemAndChip() throws {
        let charging = ChipBarPowerReading(
            hasBattery: true, onAdapter: true, isCharging: true, batteryPercent: 65,
            adapterWatts: 65, batteryWatts: 20, systemWatts: 45,
            sourceLabel: "SMC", live: true)
        let topology = try #require(PowerFlowTopology(reading: charging, chipWatts: 15))
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

    @Test func desktopBreakdownUsesInternalPowerAndKeepsItWhenChipDataIsMissing() throws {
        let reading = ChipBarPowerReading(
            hasBattery: false, onAdapter: true, isCharging: false, batteryPercent: nil,
            adapterWatts: nil, batteryWatts: nil, systemWatts: 48, sourceLabel: "SMC PSTR", live: true)

        let flow = try #require(PowerFlowTopology(reading: reading, chipWatts: 12))
        #expect(flow.mode == .desktop)
        #expect(flow.hasBreakdown)
        #expect(flow.systemWatts == 48)
        #expect(flow.chipWatts == 12)
        #expect(flow.otherWatts == 36)
        #expect(!flow.hasBatteryTransfer)

        for chip in [nil, 49, Double.nan] {
            let partial = try #require(PowerFlowTopology(reading: reading, chipWatts: chip))
            #expect(partial.systemWatts == 48)
            #expect(!partial.hasBreakdown)
        }
        #expect(PowerFlowTopology(reading: .unavailable, chipWatts: 12) == nil)
    }

    @Test func laptopSankeyKeepsSmallBranchesVisibleAndJunctionsAligned() {
        let assist = LaptopSankeyGeometry.make(systemWatts: 10, chargeWatts: 0,
                                                assistWatts: 9.7, chipWatts: 0.1)
        let minimum = LaptopSankeyGeometry.minimumRibbonHeight
        #expect(assist.inputHeight == minimum)
        #expect(assist.chipHeight == minimum)
        #expect(assist.chargeHeight == 0)
        #expect(abs(assist.inputHeight + assist.assistHeight - assist.systemHeight) < 0.001)
        #expect(abs(assist.chipHeight + assist.otherHeight - assist.systemHeight) < 0.001)

        let charge = LaptopSankeyGeometry.make(systemWatts: 10, chargeWatts: 0.6,
                                                 assistWatts: 0, chipWatts: 10)
        #expect(charge.chargeHeight == minimum)
        #expect(charge.otherHeight == 0)
        #expect(charge.assistHeight == 0)
        #expect(abs(charge.systemHeight + charge.chargeHeight - charge.inputHeight) < 0.001)
    }

    @Test func laptopThreeStageAdaptsToBatteryOnlyAdapterOnlyAndCombinedSupply() throws {
        let onBattery = ChipBarPowerReading(
            hasBattery: true, onAdapter: false, isCharging: false, batteryPercent: 40,
            adapterWatts: 0, batteryWatts: -25, systemWatts: 25,
            sourceLabel: "SMC", live: true)
        let battery = try #require(PowerFlowTopology(reading: onBattery, chipWatts: 10))
        #expect(battery.mode == .battery)
        #expect(battery.sourceWatts == 25)
        #expect(battery.chargeWatts == 0)
        #expect(battery.otherWatts == 15)
        #expect(!battery.hasBatteryTransfer)

        let adapterOnly = ChipBarPowerReading(
            hasBattery: true, onAdapter: true, isCharging: false, batteryPercent: 80,
            adapterWatts: 32, batteryWatts: 0, systemWatts: 32,
            sourceLabel: "SMC", live: true)
        let adapter = try #require(PowerFlowTopology(reading: adapterOnly, chipWatts: 12))
        #expect(adapter.mode == .adapter)
        #expect(adapter.chargeWatts == 0)
        #expect(!adapter.hasBatteryTransfer)

        let assisting = ChipBarPowerReading(
            hasBattery: true, onAdapter: true, isCharging: false, batteryPercent: 60,
            adapterWatts: 25, batteryWatts: -15, systemWatts: 40,
            sourceLabel: "SMC", live: true)
        let assisted = try #require(PowerFlowTopology(reading: assisting, chipWatts: 18))
        #expect(assisted.mode == .adapterAssisted)
        #expect(assisted.sourceWatts == 25)
        #expect(assisted.assistWatts == 15)
        #expect(assisted.chargeWatts == 0)
        #expect(assisted.hasBatteryTransfer)
        #expect(assisted.sourceWatts + assisted.assistWatts == assisted.systemWatts)
        let chart = LaptopSankeyGeometry.make(assisted)
        #expect(abs(chart.systemHeight - chart.inputHeight - chart.assistHeight) < 0.001)
        #expect(chart.leftTop == chart.assistTop + chart.assistHeight + LaptopSankeyGeometry.gap)
        #expect(chart.chipTop == chart.systemTop - LaptopSankeyGeometry.gap / 2)
        #expect(chart.otherTop == chart.systemTop + chart.chipHeight + LaptopSankeyGeometry.gap / 2)
    }

    @Test func powerBranchesSpreadEvenlyAroundSystemNode() {
        let split = LaptopSankeyGeometry.make(systemWatts: 48.1, chargeWatts: 0,
                                                assistWatts: 0, chipWatts: 11.6)
        let offset = LaptopSankeyGeometry.gap / 2
        #expect(split.chipTop == split.systemTop - offset)
        #expect(split.otherTop == split.systemTop + split.chipHeight + offset)

        let unsplit = LaptopSankeyGeometry.make(systemWatts: 12, chargeWatts: 0,
                                                  assistWatts: 0, chipWatts: 12)
        #expect(unsplit.chipTop == unsplit.systemTop)
        #expect(unsplit.otherHeight == 0)
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
        let flow = try #require(PowerFlowTopology(
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
        let full = try #require(PowerFlowTopology(reading: charged, chipWatts: 7.8))
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
        #expect(PowerFlowTopology(reading: reading(adapter: 65, battery: 20,
                                                     system: 45), chipWatts: 55) == nil)
        #expect(PowerFlowTopology(reading: reading(adapter: 65, battery: 20,
                                                     system: 35), chipWatts: 15) == nil)
        #expect(PowerFlowTopology(reading: reading(adapter: nil, battery: 20,
                                                     system: 45), chipWatts: 15) == nil)
        #expect(PowerFlowTopology(reading: reading(adapter: 65, battery: nil,
                                                     system: 45), chipWatts: 15) == nil)
        #expect(PowerFlowTopology(reading: reading(adapter: 65, battery: 20,
                                                     system: 45, charging: false), chipWatts: 15) == nil)
        #expect(PowerFlowTopology(reading: reading(adapter: 65, battery: 20,
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
