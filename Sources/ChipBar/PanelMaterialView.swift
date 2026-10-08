import AppKit

/// A single system-rendered material behind the existing monitoring dashboard.
/// Public Objective-C lookup keeps macOS 13+ and older Xcode SDK builds supported.
@MainActor final class PanelMaterialView: NSView {
    private let materialView: NSView
    let materialName: String

    init(contentView: NSView) {
        if #available(macOS 26.0, *), !CommandLine.arguments.contains("--legacy-material"),
           let glassClass = NSClassFromString("NSGlassEffectView") as? NSView.Type {
            let glass = glassClass.init(frame: .zero)
            // These are documented NSGlassEffectView properties, not private APIs.
            glass.setValue(NSNumber(value: 20), forKey: "cornerRadius")
            glass.setValue(NSNumber(value: 0), forKey: "style") // .regular
            glass.setValue(contentView, forKey: "contentView")
            materialView = glass
            materialName = "Liquid Glass"
        } else {
            let effect = NSVisualEffectView(frame: .zero)
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 20
            effect.layer?.masksToBounds = true
            effect.addSubview(contentView)
            materialView = effect
            materialName = "System frosted glass"
        }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
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
