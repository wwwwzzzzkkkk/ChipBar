import SwiftUI

/// One shared, single-selection segmented control. A single glass capsule
/// travels behind the labels (rather than recreating a selected background
/// on every sample, which used to produce flashes and two-stage jumps).
struct LiquidGlassSegment<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var id: Value { value }
}

struct LiquidGlassSegmentedSelector<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [LiquidGlassSegment<Value>]
    let accessibilityLabel: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let inset: CGFloat = 4
            let width = max(1, (proxy.size.width - inset * 2) / CGFloat(max(options.count, 1)))
            let selectedIndex = CGFloat(options.firstIndex { $0.value == selection } ?? 0)

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.065))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.075), lineWidth: 0.6)
                    }

                // The same native glass droplet glides and gently stretches
                // across all choices. It does not create another glass panel
                // or change the size of the enclosing settings tile.
                LiquidGlassSelectionDroplet()
                    .frame(width: max(1, width - 2), height: 34)
                    .modifier(LiquidGlassTravel(index: selectedIndex, step: width))
                    .padding(.leading, inset + 1)
                    .allowsHitTesting(false)

                HStack(spacing: 0) {
                    ForEach(options) { option in
                        let selected = selection == option.value
                        Button {
                            guard !selected else { return }
                            withAnimation(ChipBarMotion.optional(ChipBarMotion.liquidSelection,
                                                                 reduceMotion: reduceMotion)) {
                                selection = option.value
                            }
                        } label: {
                            Text(option.title)
                                .font(.system(size: 12, weight: selected ? .semibold : .medium))
                                .foregroundStyle(selected ? Color.primary : Color.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                                .frame(width: width, height: 40)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(option.title)
                        .accessibilityValue(selected ? "已选中" : "未选中")
                    }
                }
                .padding(.horizontal, inset)
            }
            .frame(width: proxy.size.width, height: 40)
        }
        .frame(height: 40)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// Interpolates the capsule position itself, so even fast multi-segment taps
/// animate smoothly. A subtle elastic horizontal swell occurs only in flight.
private struct LiquidGlassTravel: GeometryEffect {
    var index: CGFloat
    let step: CGFloat

    var animatableData: CGFloat {
        get { index }
        set { index = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let distanceFromStop = abs(index - index.rounded())
        let stretch = 1 + 0.14 * sin(distanceFromStop * .pi)
        let transform = CGAffineTransform(translationX: index * step, y: 0)
            .translatedBy(x: size.width / 2, y: size.height / 2)
            .scaledBy(x: stretch, y: 1)
            .translatedBy(x: -size.width / 2, y: -size.height / 2)
        return ProjectionTransform(transform)
    }
}

private struct LiquidGlassSelectionDroplet: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private let tint = Color(red: 0.30, green: 0.68, blue: 0.86)
    private var rim: LinearGradient {
        LinearGradient(colors: [
            Color.white.opacity(0.75),
            Color.white.opacity(0.18),
            Color.primary.opacity(0.20)
        ], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    @ViewBuilder var body: some View {
        if reduceTransparency {
            Capsule(style: .continuous)
                .fill(tint.opacity(0.25))
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(tint.opacity(0.55), lineWidth: 1)
                }
        } else if #available(macOS 26.0, *) {
            Capsule(style: .continuous)
                .fill(Color.clear)
                .glassEffect(.regular.tint(tint.opacity(0.22)).interactive(true),
                             in: Capsule(style: .continuous))
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(rim, lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.12), radius: 6, x: 0, y: 2)
        } else {
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay { Capsule(style: .continuous).fill(tint.opacity(0.14)) }
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(rim, lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.10), radius: 6, x: 0, y: 2)
        }
    }
}
