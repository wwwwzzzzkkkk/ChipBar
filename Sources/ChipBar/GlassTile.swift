import SwiftUI

/// Surface styling only: never owns samples, timers, or measurement state.
/// All Home tiles participate in one GlassEffectContainer to let the system
/// coordinate rendering and pointer interactions on macOS 26/27.
struct GlassTileModifier: ViewModifier {
    let radius: CGFloat
    let tint: Color?
    let interactive: Bool
    let subdued: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.compactDashboard) private var compact

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DashboardLayout.tileCornerRadius(radius, compact: compact),
                         style: .continuous)
    }

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(Color(nsColor: .windowBackgroundColor), in: shape)
                .overlay { shape.strokeBorder(.primary.opacity(0.14), lineWidth: 1) }
        } else if subdued {
            content
                .background(Color.primary.opacity(0.06), in: shape)
                .overlay { shape.strokeBorder(Color.primary.opacity(0.07), lineWidth: 1) }
        } else if #available(macOS 26.0, *) {
            content.glassEffect(
                .regular.tint(tint).interactive(interactive),
                in: shape
            )
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay {
                    shape.strokeBorder(
                        LinearGradient(stops: [
                            .init(color: .white.opacity(0.55), location: 0),
                            .init(color: .white.opacity(0), location: 0.5),
                            .init(color: .white.opacity(0.20), location: 1)
                        ], startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1
                    )
                }
                .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 5)
        }
    }
}

extension View {
    func glassTile(radius: CGFloat = 26,
                   tint: Color? = nil,
                   interactive: Bool = false,
                   subdued: Bool = false) -> some View {
        modifier(GlassTileModifier(radius: radius, tint: tint, interactive: interactive, subdued: subdued))
    }
}

/// A selected menu item is white and legible in both light/dark appearance.
/// Unselected items reuse the glassTile surface instead of drawing a second
/// opaque backdrop underneath the glass.
struct MenuChoiceSurface: ViewModifier {
    let selected: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if selected {
            content
                .background(Color.white, in: Capsule(style: .continuous))
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(Color.black.opacity(0.10), lineWidth: 0.7)
                }
                .foregroundStyle(Color.black)
        } else {
            content.glassTile(radius: 17, interactive: true)
        }
    }
}

/// Wrap the dashboard in exactly one glass coordinator, without changing the
/// legacy macOS view hierarchy or creating nested glass around chart strokes.
struct DashboardGlassContainer<Content: View>: View {
    @Environment(\.compactDashboard) private var compact
    let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    @ViewBuilder var body: some View {
        if #available(macOS 26.0, *) {
            // Keep the blend distance below the compact mosaic's card gaps.
            GlassEffectContainer(spacing: compact ? 2 : 10) { content() }
        } else {
            content()
        }
    }
}
