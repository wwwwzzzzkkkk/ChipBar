import Foundation
import Combine
import Testing
@testable import ChipBar
import ChipBarCore

@MainActor struct DashboardOpeningStateTests {
    @Test func normalReopenResetsEveryEphemeralControl() {
        let state = DashboardState()
        state.sidePanel = .externalDisk
        state.selectedExternalVolumeID = "/Volumes/Zark"
        state.chartMetric = .cpu
        state.showSettings = true
        state.showApplications = true
        state.applicationsExpansion = 1
        state.showSSDDetails = true
        state.ssdExpansion = 1
        state.showSystemDetails = true
        state.ssdDetailsHeight = 200
        state.applicationMetric = .memory

        state.resetForOpening(arguments: ["ChipBar"])

        #expect(state.sidePanel == nil)
        #expect(state.selectedExternalVolumeID == nil)
        #expect(state.chartMetric == .total)
        #expect(!state.showSettings)
        #expect(!state.showApplications)
        #expect(state.applicationsExpansion == 0)
        #expect(!state.showSSDDetails)
        #expect(state.ssdExpansion == 0)
        #expect(!state.showSystemDetails)
        #expect(state.ssdDetailsHeight == 0)
        #expect(state.applicationMetric == .cpu)
    }

    @Test func sidecardApplicationDisclosureUpdatesBothLayoutAndState() {
        let state = DashboardState()
        state.toggleApplications()
        #expect(state.showApplications)
        #expect(state.applicationsExpansion == 1)
        state.toggleApplications()
        #expect(!state.showApplications)
        #expect(state.applicationsExpansion == 0)
    }

    @Test func sidePanelNotificationsCarryNewValueBeforeStoredStateChanges() {
        let state = DashboardState()
        var emitted: DashboardSidePanelKind?
        var storedAtEmission: DashboardSidePanelKind?
        let observation = state.$sidePanel.dropFirst().sink { value in
            emitted = value
            storedAtEmission = state.sidePanel
        }
        withExtendedLifetime(observation) {
            state.sidePanel = .power
            #expect(emitted == .power)
            #expect(storedAtEmission == nil)
            state.sidePanel = .applications
            #expect(emitted == .applications)
            #expect(storedAtEmission == .power)
        }
    }

    @Test func sidePanelHeightsMatchThreeIndependentPages() {
        #expect(SidePanelLayout.width == 314)
        #expect(SidePanelLayout.contentWidth == SidePanelLayout.width - 2 * SidePanelLayout.padding)
        #expect(SidePanelLayout.height(for: .applications) == SidePanelLayout.applicationHeight)
        #expect(SidePanelLayout.height(for: .power) == SidePanelLayout.powerHeight)
        #expect(SidePanelLayout.height(for: .externalDisk) == SidePanelLayout.diskHeight)
        #expect(SidePanelLayout.powerHeight > SidePanelLayout.applicationHeight)
        #expect(SidePanelLayout.diskHeight > SidePanelLayout.applicationHeight)
    }

    @Test func previewFixtureBuildsChartWithoutMenuPanel() throws {
        let fixture = try Sample.decode(Data("{\"all_power\":12.5}".utf8))
        let monitor = Monitor(start: false, initialSample: fixture)
        #expect(monitor.powerChart.points.count == 1)
        #expect(monitor.powerChart.points.first?.power == 12.5)
    }

    @Test func screenshotsKeepTheirExplicitQAOverrides() {
        let state = DashboardState()
        state.resetForOpening(arguments: ["ChipBar", "--apps", "--ssd-details", "--apps-gpu"])
        #expect(state.showApplications)
        #expect(state.applicationsExpansion == 1)
        #expect(state.showSSDDetails)
        #expect(state.ssdExpansion == 1)
        #expect(state.showSystemDetails)
        #expect(state.applicationMetric == .gpu)

        state.resetForOpening(arguments: ["ChipBar", "--system-details", "--apps-ane"])
        #expect(!state.showApplications)
        #expect(!state.showSSDDetails)
        #expect(state.showSystemDetails)
        #expect(state.applicationMetric == .ane)
    }
}
