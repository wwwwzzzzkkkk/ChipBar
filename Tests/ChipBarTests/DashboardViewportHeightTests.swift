import AppKit
import Testing
@testable import ChipBar

struct DashboardViewportHeightTests {
    @Test func settingsContentShrinksAfterPageSlide() {
        #expect(DashboardViewportHeight.fitted(
            content: 520, maximum: 850, pinned: nil) == 520)
        #expect(DashboardViewportHeight.fitted(
            content: 520, maximum: 850, pinned: 810) == 810)
    }

    @Test func tallContentRespectsAvailableScreenWithoutCroppingDocument() {
        #expect(DashboardViewportHeight.fitted(
            content: 1020, maximum: 760, pinned: nil) == 760)
        #expect(DashboardViewportHeight.fitted(
            content: 520, maximum: 760, pinned: 950) == 760)
    }
}
