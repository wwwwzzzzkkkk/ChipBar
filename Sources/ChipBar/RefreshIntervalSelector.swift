import SwiftUI

/// Shared floating-glass capsule selector. Power hardware SMC polling remains
/// independent (3 s) of this user-configured macmon metric interval.
struct RefreshIntervalSelector: View {
    @Binding var selection: Int

    private let values = [1_000, 2_000, 5_000, 10_000]

    var body: some View {
        LiquidGlassSegmentedSelector(
            selection: $selection,
            options: values.map { LiquidGlassSegment(value: $0, title: "\($0 / 1_000) 秒") },
            accessibilityLabel: "刷新频率"
        )
    }
}
