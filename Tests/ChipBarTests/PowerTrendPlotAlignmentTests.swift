import SwiftUI
import Testing
@testable import ChipBar

struct PowerTrendPlotAlignmentTests {
    @Test func axisGridAndDataUseSameVerticalCoordinates() {
        let height: CGFloat = 52
        #expect(PowerTrendGeometry.y(fraction: 0, height: height) == 6)
        #expect(PowerTrendGeometry.y(fraction: 0.5, height: height) == 26)
        #expect(PowerTrendGeometry.y(fraction: 1, height: height) == 46)
    }

    @Test func shortChartsKeepInBoundsAndSymmetricPadding() {
        let height: CGFloat = 10
        let top = PowerTrendGeometry.y(fraction: 0, height: height)
        let bottom = PowerTrendGeometry.y(fraction: 1, height: height)
        #expect(top >= 0)
        #expect(bottom <= height)
        #expect(top == height - bottom)
    }
}
