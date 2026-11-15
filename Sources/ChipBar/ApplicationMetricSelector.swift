import SwiftUI

/// A moving Liquid Glass droplet chooses exactly one application resource.
/// The ranking page's own transition stays separate from this selection effect.
struct ApplicationMetricSelector: View {
    @Binding var selection: ApplicationResource

    var body: some View {
        LiquidGlassSegmentedSelector(
            selection: $selection,
            options: ApplicationResource.allCases.map {
                LiquidGlassSegment(value: $0, title: $0.rawValue)
            },
            accessibilityLabel: "应用占用指标"
        )
    }
}
