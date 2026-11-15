import SwiftUI
import QuartzCore

/// A consistent, critically damped motion language. Interactive spring
/// animations stay interruptible without overshooting when clicked rapidly.
/// Short, interrupted gestures should not stack expensive layout animations.
/// Respect Reduce Motion throughout the dashboard.
enum ChipBarMotion {
    static let tap = Animation.spring(response: 0.24, dampingFraction: 1.0)
    static let disclosure = Animation.spring(response: 0.35, dampingFraction: 1.0)
    static let selection = Animation.spring(response: 0.30, dampingFraction: 1.0)
    // Slightly elastic liquid capsule, only driven by deliberate selection taps.
    static let liquidSelection = Animation.spring(response: 0.48, dampingFraction: 0.78)
    // Layered application resource switch: the old list recedes and fades,
    // while the next metric enters above it. Keep this under one-third second.
    static let resourceStack = Animation.easeInOut(duration: 0.28)
    static let navigation = Animation.easeInOut(duration: 0.24)

    static func optional(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}

/// Transient press animation does not remount the button or resize its parent.
/// It covers all normal dashboard buttons (settings, back, pause, selectors).
struct ChipBarPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.965 : 1))
            .opacity(configuration.isPressed && !reduceMotion ? 0.78 : 1)
            .animation(ChipBarMotion.optional(.spring(response: 0.22, dampingFraction: 1.0),
                                              reduceMotion: reduceMotion),
                       value: configuration.isPressed)
    }
}

/// The same restrained disclosure affordance throughout AppKit/SwiftUI.
/// Chevron rotation is animated by the state change, not by polling samples.
struct ChipBarSectionToggle: View {
    let title: String
    let systemImage: String
    let expanded: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Label(title, systemImage: systemImage)
                    .font(.subheadline.weight(.medium))
                Spacer(minLength: 6)
                Text(expanded ? "收起" : "展开")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .rotationEffect(.degrees(expanded ? 180 : 0))
                    .animation(ChipBarMotion.optional(ChipBarMotion.disclosure,
                                                      reduceMotion: reduceMotion), value: expanded)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(ChipBarPressStyle())
        .accessibilityLabel("\(title)，\(expanded ? "收起" : "展开")")
    }
}
