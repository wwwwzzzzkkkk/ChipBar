import Testing
@testable import ChipBarCore

struct NetworkActivityTests {
    @Test func ratesAndInterfaceChanges() throws {
        var activity = NetworkActivity()
        #expect(activity.update(["en0": NetworkBytes(received: 10, sent: 20)], at: 1) == nil)
        let next = activity.update([
            "en0": NetworkBytes(received: 2_000_010, sent: 500_020),
            "en1": NetworkBytes(received: 9_000_000, sent: 8_000_000)
        ], at: 3)
        let rate = try #require(next)
        #expect(rate.download == 1_000_000)
        #expect(rate.upload == 250_000)
        let last = activity.update(["en1": NetworkBytes(received: 9_000_100, sent: 8_000_300)], at: 4)
        let remaining = try #require(last)
        #expect(remaining.download == 100)
        #expect(remaining.upload == 300)
    }

    @Test func resetDisconnectAndSleepNeverSpike() {
        var activity = NetworkActivity()
        _ = activity.update(["en0": NetworkBytes(received: UInt64.max - 10, sent: 20)], at: 1)
        #expect(activity.update(["en0": NetworkBytes(received: 1, sent: 21)], at: 2) == nil)
        #expect(activity.update([:], at: 3) == nil)
        #expect(activity.update(["en0": NetworkBytes(received: 9_000, sent: 9_000)], at: 4) == nil)
        #expect(activity.update(["en0": NetworkBytes(received: 9_001, sent: 9_001)], at: 40) == nil)
        #expect(activity.update(["en0": NetworkBytes(received: 9_002, sent: 9_002)], at: 40) == nil)
    }

    @Test func units() {
        #expect(NetworkRate.text(nil) == "—")
        #expect(NetworkRate.text(0) == "0 B/s")
        #expect(NetworkRate.text(250_000) == "250.0 KB/s")
        #expect(NetworkRate.text(1_200_000) == "1.2 MB/s")
    }
}
