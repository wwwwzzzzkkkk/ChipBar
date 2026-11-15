import Testing
import ChipBarCore
@testable import ChipBar

struct NetworkSamplingPolicyTests {
    @Test func openingDashboardDoesNotActivateUnusedNetworkCounters() {
        #expect(!NetworkSamplingPolicy.isActive(
            startsAutomatically: true, paused: false, sleeping: false,
            menuItems: [.power, .disk]))
        #expect(!NetworkSamplingPolicy.isActive(
            startsAutomatically: true, paused: false, sleeping: false,
            menuItems: [.power]))
    }

    @Test func menuNetworkReadoutsRemainLiveWhenEnabled() {
        #expect(NetworkSamplingPolicy.isActive(
            startsAutomatically: true, paused: false, sleeping: false,
            menuItems: [.network]))
        #expect(!NetworkSamplingPolicy.isActive(
            startsAutomatically: true, paused: true, sleeping: false,
            menuItems: [.network]))
        #expect(!NetworkSamplingPolicy.isActive(
            startsAutomatically: true, paused: false, sleeping: true,
            menuItems: [.network]))
        #expect(!NetworkSamplingPolicy.isActive(
            startsAutomatically: false, paused: false, sleeping: false,
            menuItems: [.network]))
    }
}
