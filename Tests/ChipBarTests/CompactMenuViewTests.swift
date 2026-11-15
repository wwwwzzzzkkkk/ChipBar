import AppKit
import Testing
import ChipBarCore
@testable import ChipBar

@MainActor struct CompactMenuViewTests {
    @Test func rateChangesReserveColumnsAndPreferencesReleaseWidth() {
        let view = CompactMenuView()
        let first = view.update([MenuReadout("net", "↓29.7K/s", "↑4.1K/s", pairedValues: true)], showsLogo: false)
        let wider = view.update([MenuReadout("net", "↓999M/s", "↑999M/s", pairedValues: true)], showsLogo: false)
        let idle = view.update([MenuReadout("net", "↓0B/s", "↑0B/s", pairedValues: true)], showsLogo: false)
        #expect(wider >= first)
        #expect(idle == wider)
        let hidden = view.update([], showsLogo: false)
        #expect(hidden == 24)
        #expect(view.hitTest(.zero) == nil)
    }
}
