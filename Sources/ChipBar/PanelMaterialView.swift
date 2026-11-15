import AppKit

/// One rounded material host for the full dashboard. SwiftUI tiles add their
/// own glass effects inside this host; charts and text stay material-free.
@MainActor final class PanelMaterialView: NSView {
    private let materialView: NSView
    let materialName: String

    init(contentView: NSView) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            let solid = NSView(frame: .zero)
            solid.wantsLayer = true
            solid.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            solid.layer?.cornerRadius = 30
            solid.layer?.cornerCurve = .continuous
            solid.layer?.masksToBounds = true
            solid.addSubview(contentView)
            materialView = solid
            materialName = "Reduced transparency"
        } else if #available(macOS 26.0, *),
                  !CommandLine.arguments.contains("--legacy-material") {
            let glass = NSGlassEffectView(frame: .zero)
            glass.cornerRadius = 30
            glass.style = .regular
            glass.contentView = contentView
            materialView = glass
            materialName = "Liquid Glass"
        } else {
            let effect = NSVisualEffectView(frame: .zero)
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 30
            effect.layer?.cornerCurve = .continuous
            effect.layer?.masksToBounds = true
            effect.addSubview(contentView)
            materialView = effect
            materialName = "System HUD material"
        }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.cornerRadius = 30
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        materialView.autoresizingMask = [.width, .height]
        contentView.autoresizingMask = [.width, .height]
        autoresizingMask = [.width, .height]
        addSubview(materialView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        materialView.frame = bounds
    }

    var materialClassName: String { NSStringFromClass(type(of: materialView)) }
}
