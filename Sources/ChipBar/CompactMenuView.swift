import AppKit
import ChipBarCore

/// Drawing inside the native status button keeps its click handling and highlight.
@MainActor final class CompactMenuView: NSView {
    private var readouts: [MenuReadout] = []
    private var widths: [String: CGFloat] = [:]
    private var showsLogo = true
    private var preferredWidth: CGFloat = 24
    private let paragraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle(); style.alignment = .center; return style
    }()
    private let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
    private let labelFont = NSFont.systemFont(ofSize: 7, weight: .medium)
    private let rateFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(_ next: [MenuReadout], showsLogo: Bool) -> CGFloat {
        guard next != readouts || self.showsLogo != showsLogo else { return preferredWidth }
        if next.map(\.id) != readouts.map(\.id) || self.showsLogo != showsLogo { widths = [:] }
        for item in next {
            if widths[item.id] != nil, readouts.first(where: { $0.id == item.id }) == item { continue }
            let top = (item.top as NSString).size(withAttributes: [.font: item.pairedValues ? rateFont : valueFont]).width
            let bottom = (item.bottom as NSString).size(withAttributes: [.font: item.pairedValues ? rateFont : labelFont]).width
            // Reserve each column independently so a changing rate never shifts its neighbours.
            widths[item.id] = max(widths[item.id] ?? 0, ceil(max(22, max(top, bottom))))
        }
        readouts = next; self.showsLogo = showsLogo
        needsDisplay = true
        let columns = next.reduce(CGFloat(0)) { $0 + (widths[$1.id] ?? 22) }
        let gaps = CGFloat(max(0, next.count - 1)) * 9
        preferredWidth = max(24, 8 + columns + gaps + (showsLogo ? (next.isEmpty ? 10 : 20) : 0))
        return preferredWidth
    }

    override func draw(_ dirtyRect: NSRect) {
        let highlighted = (superview as? NSStatusBarButton)?.cell?.isHighlighted == true
        let foreground = highlighted ? NSColor.selectedMenuItemTextColor : NSColor.labelColor
        let secondary = foreground.withAlphaComponent(highlighted ? 0.85 : 0.68)
        let rowY = (bounds.height - 22) / 2
        var x: CGFloat = readouts.isEmpty && showsLogo ? (bounds.width - 10) / 2 : 4
        if showsLogo {
            let y = (bounds.height - 13) / 2
            let bolt = NSBezierPath()
            bolt.move(to: NSPoint(x: x + 7, y: y))
            bolt.line(to: NSPoint(x: x, y: y + 8))
            bolt.line(to: NSPoint(x: x + 4, y: y + 8))
            bolt.line(to: NSPoint(x: x + 2, y: y + 13))
            bolt.line(to: NSPoint(x: x + 10, y: y + 5))
            bolt.line(to: NSPoint(x: x + 6, y: y + 5))
            bolt.close(); foreground.setFill(); bolt.fill()
            x += readouts.isEmpty ? 10 : 20
        }
        if readouts.isEmpty, !showsLogo {
            drawText("···", x: 0, y: (bounds.height - 12) / 2, width: bounds.width,
                     font: .systemFont(ofSize: 12), color: foreground)
        }
        for (index, item) in readouts.enumerated() {
            let width = widths[item.id] ?? 22
            drawText(item.top, x: x, y: rowY, width: width,
                     font: item.pairedValues ? rateFont : valueFont, color: foreground)
            drawText(item.bottom, x: x, y: rowY + 11, width: width,
                     font: item.pairedValues ? rateFont : labelFont,
                     color: item.pairedValues ? foreground : secondary)
            x += width
            if index < readouts.count - 1 {
                secondary.withAlphaComponent(0.22).setFill()
                NSRect(x: x + 4, y: (bounds.height - 14) / 2, width: 0.5, height: 14).fill()
                x += 9
            }
        }
    }

    private func drawText(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat, font: NSFont, color: NSColor) {
        // Both rows share the same column centre and fixed row centres. Centre
        // each font line vertically so smaller labels do not drift to the top.
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let frame = NSRect(x: x, y: y + (12 - lineHeight) / 2, width: width, height: lineHeight)
        (text as NSString).draw(in: frame,
                               withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }
}
