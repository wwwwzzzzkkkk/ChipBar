import Testing
@testable import ChipBar

struct ClusterConnectionStatusTests {
    @Test func distinctPairingAndSharingOff() {
        #expect(ClusterConnectionStatus.resolve(
            sharingEnabled: false, hasTrustedPeer: false,
            hasNearbyPeer: false, onlinePeerCount: 0,
            hasReceivedRemoteTelemetry: false) == .pairingRequired)
        #expect(ClusterConnectionStatus.resolve(
            sharingEnabled: false, hasTrustedPeer: true,
            hasNearbyPeer: false, onlinePeerCount: 0,
            hasReceivedRemoteTelemetry: false) == .sharingOff)
    }

    @Test func waitingAndOfflineAreNotConflated() {
        #expect(ClusterConnectionStatus.resolve(
            sharingEnabled: true, hasTrustedPeer: true,
            hasNearbyPeer: false, onlinePeerCount: 0,
            hasReceivedRemoteTelemetry: false) == .discovering)
        #expect(ClusterConnectionStatus.resolve(
            sharingEnabled: true, hasTrustedPeer: true,
            hasNearbyPeer: true, onlinePeerCount: 0,
            hasReceivedRemoteTelemetry: false) == .waitingForData)
        #expect(ClusterConnectionStatus.resolve(
            sharingEnabled: true, hasTrustedPeer: true,
            hasNearbyPeer: false, onlinePeerCount: 0,
            hasReceivedRemoteTelemetry: true) == .offline)
        #expect(ClusterConnectionStatus.resolve(
            sharingEnabled: true, hasTrustedPeer: true,
            hasNearbyPeer: true, onlinePeerCount: 1,
            hasReceivedRemoteTelemetry: true) == .online)
    }

    @Test func displayStatesHaveDistinctIconsAndEnglishDescriptions() {
        let states: [ClusterConnectionStatus] = [
            .pairingRequired, .sharingOff, .discovering,
            .waitingForData, .online, .offline
        ]
        #expect(Set(states.map(\.symbol)).count == states.count)
        #expect(states.allSatisfy { !$0.title.isEmpty && !$0.hint.isEmpty })
    }
}
