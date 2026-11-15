import CoreGraphics
import Testing
@testable import ChipBar

struct DisclosurePanelSizingTests {
    @Test func settingsReturnUsesPreviouslyMeasuredHomeWithoutTwoPhaseResize() {
        let home: CGFloat = 582
        // Settings was screen-capped to 810 while editing preferences.
        #expect(DisclosurePanelSizing.navigationHeight(
            enteringSettings: false, currentHeight: 940,
            homeHeight: home, settingsHeight: 940, maximumHeight: 810
        ) == 582)
        #expect(DisclosurePanelSizing.navigationHeight(
            enteringSettings: true, currentHeight: home,
            homeHeight: home, settingsHeight: nil, maximumHeight: 810
        ) == 810)
    }

    @Test func navigationUsesExactCachedSizesAndRespectsScreenCap() {
        #expect(DisclosurePanelSizing.navigationHeight(
            enteringSettings: true, currentHeight: 650,
            homeHeight: 650, settingsHeight: 710, maximumHeight: 850
        ) == 710)
        #expect(DisclosurePanelSizing.navigationHeight(
            enteringSettings: false, currentHeight: 710,
            homeHeight: 900, settingsHeight: 710, maximumHeight: 750
        ) == 750)
    }

    @Test func interruptionProgressMatchesWindowEaseInOut() {
        #expect(DisclosurePanelSizing.easeInOutProgress(-1) == 0)
        #expect(DisclosurePanelSizing.easeInOutProgress(0) == 0)
        #expect(abs(DisclosurePanelSizing.easeInOutProgress(0.5) - 0.5) < 0.001)
        #expect(DisclosurePanelSizing.easeInOutProgress(1) == 1)
        #expect(DisclosurePanelSizing.easeInOutProgress(2) == 1)
        let quarter = DisclosurePanelSizing.easeInOutProgress(0.25)
        #expect(quarter > 0.12 && quarter < 0.14)
        #expect(abs(DisclosurePanelSizing.easeInOutProgress(0.75) - (1 - quarter)) < 0.001)
    }

    @Test func reversingMoreAlwaysReturnsToStableCollapsedHeight() {
        let collapsed: CGFloat = 602
        let opened = DisclosurePanelSizing.expandedDocumentHeight(
            collapsedHeight: collapsed, applications: 1, ssd: 0, ssdDetailsHeight: 0)
        #expect(opened == 706)
        let recovered = DisclosurePanelSizing.collapsedDocumentHeight(
            measuredHeight: opened, applications: 1, ssd: 0, ssdDetailsHeight: 0)
        #expect(recovered == collapsed)
        // The window may still be at 660 during interruption. Its current
        // presentation height must never be used as a new content baseline.
        let close = DisclosurePanelSizing.expandedDocumentHeight(
            collapsedHeight: recovered, applications: 0, ssd: 0, ssdDetailsHeight: 0)
        #expect(close == collapsed)
        let reopen = DisclosurePanelSizing.expandedDocumentHeight(
            collapsedHeight: recovered, applications: 1, ssd: 0, ssdDetailsHeight: 0)
        #expect(reopen == opened)
    }

    @Test func overlappingSSDAndApplicationExpansionsKeepIndependentHeightContributions() {
        let initial: CGFloat = 600
        let ssd: CGFloat = 188
        let both = DisclosurePanelSizing.expandedDocumentHeight(
            collapsedHeight: initial, applications: 1, ssd: 1, ssdDetailsHeight: ssd)
        #expect(both == 892)
        let base = DisclosurePanelSizing.collapsedDocumentHeight(
            measuredHeight: both, applications: 1, ssd: 1, ssdDetailsHeight: ssd)
        #expect(base == initial)
        let onlySSD = DisclosurePanelSizing.expandedDocumentHeight(
            collapsedHeight: base, applications: 0, ssd: 1, ssdDetailsHeight: ssd)
        #expect(onlySSD == 788)
    }

    @Test func collapseUsesFullDocumentHeightWhenExpandedWindowWasScreenCapped() {
        // The expanded document is 1,000 pt tall, but the visible panel was
        // capped at 800 pt. Closing a 300 pt section should target 700 pt.
        #expect(DisclosurePanelSizing.targetHeight(
            documentHeight: 1_000,
            contentHeightDelta: -300,
            maximumHeight: 800
        ) == 700)
    }

    @Test func expansionRemainsCappedAndSmallPanelsKeepTheirMinimumHeight() {
        #expect(DisclosurePanelSizing.targetHeight(
            documentHeight: 700,
            contentHeightDelta: 400,
            maximumHeight: 800
        ) == 800)
        #expect(DisclosurePanelSizing.targetHeight(
            documentHeight: 280,
            contentHeightDelta: -100,
            maximumHeight: 800
        ) == 250)
    }
}
