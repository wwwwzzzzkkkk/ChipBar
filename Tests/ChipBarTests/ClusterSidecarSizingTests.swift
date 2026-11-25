import Foundation
import Testing
@testable import ChipBar

struct ClusterSidecarSizingTests {
    @Test func everySidecardMountsFinalContentBeforeItsFirstVisibleFrame() {
        for kind in [DashboardSidePanelKind.cluster, .power, .applications, .externalDisk] {
            #expect(SidePanelOpeningPolicy.presentsFinalContentBeforeShowing(kind))
        }
        #expect(SidePanelLayout.clusterDisclosureAnimationDuration > 0)
    }

    @Test func sidecarRevealKeepsTheEdgeNearestHomeFixed() {
        #expect(SidePanelNavigationMotion.seamAnchor(on: .right) == 0)
        #expect(SidePanelNavigationMotion.seamAnchor(on: .left) == 1)
        #expect(SidePanelNavigationMotion.edgeOffset(on: .right) < 0)
        #expect(SidePanelNavigationMotion.edgeOffset(on: .left) > 0)
    }

    @Test func reversingARevealUsesTheRemainingDistance() {
        let open = SidePanelNavigationMotion.revealDuration(from: 0, to: 1)
        let close = SidePanelNavigationMotion.revealDuration(from: 1, to: 0)
        #expect(open == SidePanelNavigationMotion.enterDuration)
        #expect(close == SidePanelNavigationMotion.exitDuration)
        #expect(SidePanelNavigationMotion.revealDuration(from: 0.6, to: 1) < open)
        #expect(SidePanelNavigationMotion.revealDuration(from: 0.4, to: 0) < close)
    }

    @Test func nativeWindowGeometryIsCommittedOnlyIfChanged() {
        let current = CGRect(x: 500, y: 600, width: 314, height: 250)
        let target = CGRect(x: 500, y: 210, width: 420, height: 640)
        #expect(!SidePanelNavigationMotion.needsFrameCommit(from: current, to: current))
        #expect(SidePanelNavigationMotion.needsFrameCommit(from: current, to: target))
        #expect(!SidePanelNavigationMotion.needsFrameCommit(from: target, to: target))
    }

    @Test func sidecarUsesLeftWhenDestinationWidthCannotFitOnRight() throws {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 960)
        let home = CGRect(x: 800, y: 28, width: 378, height: 900)
        let narrow = try #require(SidePanelPlacement.choose(
            parent: home, visible: screen, preferredWidth: 314, preferredHeight: 250))
        let power = try #require(SidePanelPlacement.choose(
            parent: home, visible: screen, preferredWidth: 420, preferredHeight: 640))
        #expect(narrow.side == .right)
        #expect(power.side == .left)
        #expect(power.frame.maxX == home.minX - SidePanelPlacement.gap)
        #expect(!narrow.frame.intersects(home))
        #expect(!power.frame.intersects(home))
        #expect(!power.needsHorizontalScroll)
        #expect(SidePanelPlacement.requiresRelocation(
            from: narrow.frame, to: power, parent: home, visible: screen))
    }

    @Test func rightSideIsPreferredWhenBothSidesFitTheWholePage() throws {
        let screen = CGRect(x: -1920, y: 40, width: 1920, height: 1040)
        let home = CGRect(x: -1150, y: 80, width: 378, height: 700)
        let result = try #require(SidePanelPlacement.choose(
            parent: home, visible: screen, preferredWidth: 420, preferredHeight: 640))
        #expect(result.side == .right)
        #expect(result.frame.minX == home.maxX + SidePanelPlacement.gap)
        #expect(SidePanelPlacement.isLegal(result.frame, beside: home, visible: screen))
    }

    @Test func smallScreenUsesScrollableFreeIntervalRatherThanOverlap() throws {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let home = CGRect(x: 260, y: 12, width: 378, height: 470)
        let result = try #require(SidePanelPlacement.choose(
            parent: home, visible: screen, preferredWidth: 420, preferredHeight: 640))
        #expect(result.side == .right)
        #expect(result.frame.width == 345)
        #expect(result.frame.height == 484)
        #expect(result.documentWidth == 420)
        #expect(result.needsHorizontalScroll)
        #expect(SidePanelPlacement.isLegal(result.frame, beside: home, visible: screen))
        #expect(SidePanelPlacement.choose(
            parent: CGRect(x: 30, y: 8, width: 940, height: 470),
            visible: screen, preferredWidth: 420, preferredHeight: 640) == nil)
    }

    @Test func bothVisibleLegsOfCrossSideAnimationStayOutsideHome() throws {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 960)
        let home = CGRect(x: 800, y: 28, width: 378, height: 900)
        let right = try #require(SidePanelPlacement.choose(
            parent: home, visible: screen, preferredWidth: 314, preferredHeight: 250))
        let left = try #require(SidePanelPlacement.choose(
            parent: home, visible: screen, preferredWidth: 420, preferredHeight: 640))
        // Production keeps these legal native frames fixed throughout
        // the content animation, and moves between them only while hidden.
        #expect(SidePanelPlacement.isLegal(right.frame, beside: home, visible: screen))
        #expect(SidePanelPlacement.isLegal(left.frame, beside: home, visible: screen))
        #expect(SidePanelPlacement.requiresRelocation(
            from: right.frame, to: left, parent: home, visible: screen))
        #expect(!SidePanelPlacement.requiresRelocation(
            from: left.frame, to: left, parent: home, visible: screen))
        let formerlyClamped = CGRect(x: screen.maxX - 8 - 420, y: 280, width: 420, height: 640)
        #expect(formerlyClamped.intersects(home))
        #expect(SidePanelPlacement.requiresRelocation(
            from: formerlyClamped, to: left, parent: home, visible: screen))
    }

    @Test func taskDisclosurePinsWindowAndSmallFirstFitCorrectionsAreIgnored() {
        #expect(!ClusterSidecarSizing.shouldResizeWindow(
            from: 420, to: 780, available: 1100, userDisclosurePinned: true))
        #expect(ClusterSidecarSizing.shouldResizeWindow(
            from: 420, to: 780, available: 1100, userDisclosurePinned: false))
        #expect(!ClusterSidecarSizing.shouldResizeWindow(
            from: 420, to: 426, available: 1100, userDisclosurePinned: false))
        // A screen-size change is still allowed to shrink an overlong panel.
        #expect(ClusterSidecarSizing.shouldResizeWindow(
            from: 700, to: 480, available: 500, userDisclosurePinned: true))
    }

    @Test func disclosurePreservesCurrentScrollInsteadOfJumpingBackToTitle() {
        #expect(ClusterSidecarSizing.preservedScrollOffset(
            160, documentHeight: 1100, viewportHeight: 510, isFlipped: true) == 160)
        #expect(ClusterSidecarSizing.preservedScrollOffset(
            160, documentHeight: 570, viewportHeight: 510, isFlipped: true) == 60)
        #expect(ClusterSidecarSizing.preservedScrollOffset(
            0, documentHeight: 1100, viewportHeight: 510, isFlipped: true) == 0)
    }

    @Test func clusterTopIsIndependentOfParentResize() {
        let opened: CGFloat = 890
        #expect(ClusterSidecarSizing.stableTop(openedAt: opened, visibleMaxY: 1100) == 890)
        #expect(ClusterSidecarSizing.stableTop(openedAt: opened, visibleMaxY: 800) == 792)
    }

    @Test func resizedPanelKeepsTopWithoutDiscardingManualScroll() {
        #expect(ClusterSidecarSizing.isAtTop(
            offsetY: 0, documentHeight: 850, viewportHeight: 510, isFlipped: true))
        #expect(!ClusterSidecarSizing.isAtTop(
            offsetY: 150, documentHeight: 850, viewportHeight: 510, isFlipped: true))
        #expect(ClusterSidecarSizing.isAtTop(
            offsetY: 340, documentHeight: 850, viewportHeight: 510, isFlipped: false))
        #expect(!ClusterSidecarSizing.isAtTop(
            offsetY: 80, documentHeight: 850, viewportHeight: 510, isFlipped: false))
    }

    @Test func scrollTopUsesFlippedViewCoordinateSystem() {
        #expect(ClusterSidecarSizing.topScrollOffset(
            documentHeight: 850, viewportHeight: 510, isFlipped: true) == 0)
        #expect(ClusterSidecarSizing.topScrollOffset(
            documentHeight: 850, viewportHeight: 510, isFlipped: false) == 340)
        #expect(ClusterSidecarSizing.topScrollOffset(
            documentHeight: 210, viewportHeight: 510, isFlipped: false) == 0)
    }

    @Test func compactContentDoesNotLeaveLargeEmptyViewport() {
        #expect(ClusterSidecarSizing.windowHeight(content: 340, available: 1100) == 340)
        #expect(ClusterSidecarSizing.windowHeight(content: 620, available: 1100) == 620)
        #expect(ClusterSidecarSizing.windowHeight(content: 310, available: 1100) == 310)
    }

    @Test func canFitNewlyDiscoveredNodesBeforeUserDisclosure() {
        let folded = ClusterSidecarSizing.windowHeight(content: 410, available: 1000)
        let expanded = ClusterSidecarSizing.windowHeight(content: 780, available: 1000)
        #expect(expanded > folded)
        #expect(expanded == 780)
        #expect(ClusterSidecarSizing.windowHeight(content: 410, available: 1000) == folded)
    }

    @Test func shortDisplaysCapToVisibleHeightAndRequireInternalScroll() {
        #expect(ClusterSidecarSizing.windowHeight(content: 950, available: 610) == 594)
        #expect(ClusterSidecarSizing.windowHeight(content: 125, available: 600) == 210)
        #expect(ClusterSidecarSizing.windowHeight(content: .infinity, available: 600) == 210)
    }

    @Test func powerDisclosureUsesOnlySpaceBelowItsAnchor() throws {
        let screen = CGRect(x: 0, y: 24, width: 1440, height: 880)
        let parent = CGRect(x: 500, y: 200, width: 378, height: 520)
        let top = parent.maxY
        let compact = SidePanelPlacement.powerViewportHeight(content: 440, anchoredTop: top, visible: screen)
        let expanded = SidePanelPlacement.powerViewportHeight(content: 910, anchoredTop: top, visible: screen)
        #expect(compact == 440)
        #expect(expanded == top - screen.minY - SidePanelPlacement.edgeInset)
        let placement = try #require(SidePanelPlacement.choose(
            parent: parent, visible: screen, preferredWidth: 420, preferredHeight: expanded, top: top))
        #expect(placement.frame.maxY == top)
        #expect(placement.frame.minY == screen.minY + SidePanelPlacement.edgeInset)
    }

    @Test func panelKeepsTopAnchorUntilReachingScreenBottom() {
        #expect(ClusterSidecarSizing.bottomY(
            anchoredTop: 980, height: 620, visibleMinY: 24) == 360)
        #expect(ClusterSidecarSizing.bottomY(
            anchoredTop: 510, height: 600, visibleMinY: 24) == 32)
    }
}
