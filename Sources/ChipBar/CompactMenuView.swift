import AppKit
import SwiftUI
import ChipBarCore

/// Drawing inside the native status button keeps its click handling and highlight.
@MainActor final class CompactMenuView: NSView {
    private var readouts: [MenuReadout] = []
    private var widths: [String: CGFloat] = [:]
    private var showsLogo = true
    private var preferredWidth: CGFloat = 24
    private let readoutGap: CGFloat = 10
    private var coreLoads: [Double] = []
    private var coreOpacity: CGFloat = 0
    private var coreColumns: [(index: Int, warm: Bool)] = []
    private var coreTransition: (from: [Double], startedAt: TimeInterval)?
    private var coreTimer: Timer?
    private let coreTransitionDuration: TimeInterval = 0.26

    private static let coolLED = (NSColor(srgbRed: 0x38 / 255.0, green: 0xBD / 255.0, blue: 0xF8 / 255.0, alpha: 1),
                                  NSColor(srgbRed: 0, green: 0xE5 / 255.0, blue: 1, alpha: 1))
    private static let warmLED = (NSColor(srgbRed: 0xFB / 255.0, green: 0x92 / 255.0, blue: 0x3C / 255.0, alpha: 1),
                                  NSColor(srgbRed: 1, green: 0x95 / 255.0, blue: 0, alpha: 1))

    func updateCoreBackground(_ values: [Double], opacity: Double) {
        guard coreLoads != values || coreOpacity != opacity else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let sameCount = coreLoads.count == values.count
        if !sameCount {
            let labels = CPUCoreTopology.current.namesByLogicalID
            let hasSuper = labels.values.contains("超级核")
            let columns = values.indices.map { index in
                let tier = labels.count == values.count ? labels[index] : nil
                return (index: index, warm: tier == "超级核" || (!hasSuper && tier == "性能核"))
            }
            coreColumns = columns.filter { !$0.warm } + columns.filter { $0.warm }
        }
        if opacity == 0 || coreOpacity == 0 || !sameCount || window == nil
            || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            stopCoreTransition()
        } else if values != coreLoads {
            coreTransition = (displayedCoreLoads(at: now), now)
            if coreTimer == nil {
                let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
                    MainActor.assumeIsolated {
                        guard let self else { timer.invalidate(); return }
                        self.advanceCoreTransition()
                    }
                }
                coreTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
        }
        coreLoads = values
        coreOpacity = opacity
        needsDisplay = true
    }

    private func displayedCoreLoads(at now: TimeInterval) -> [Double] {
        guard let transition = coreTransition else { return coreLoads }
        let elapsed = min(1, max(0, (now - transition.startedAt) / coreTransitionDuration))
        let progress = elapsed * elapsed * (3 - 2 * elapsed)
        return zip(transition.from, coreLoads).map { start, end in
            start + (end - start) * progress
        }
    }

    private func advanceCoreTransition() {
        if let transition = coreTransition,
           ProcessInfo.processInfo.systemUptime - transition.startedAt >= coreTransitionDuration {
            stopCoreTransition()
        }
        needsDisplay = true
    }

    private func stopCoreTransition() {
        coreTimer?.invalidate()
        coreTimer = nil
        coreTransition = nil
    }
    private let paragraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle(); style.alignment = .center; return style
    }()
    private let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
    private let labelFont = NSFont.systemFont(ofSize: 7, weight: .medium)
    private let rateFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        guard newSize != frame.size else { return }
        super.setFrameSize(newSize)
        needsDisplay = true
    }

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
        let gaps = CGFloat(max(0, next.count - 1)) * readoutGap
        preferredWidth = max(24, 8 + columns + gaps + (showsLogo ? (next.isEmpty ? 10 : 20) : 0))
        return preferredWidth
    }

    override func draw(_ dirtyRect: NSRect) {
        let highlighted = (superview as? NSStatusBarButton)?.cell?.isHighlighted == true
        if !highlighted { drawCoreBackground() }
        let foreground = highlighted ? NSColor.selectedMenuItemTextColor : NSColor.labelColor
        let secondary = foreground.withAlphaComponent(highlighted ? 0.85 : 0.68)
        let shadow: NSShadow?
        if !highlighted, coreOpacity > 0, !coreColumns.isEmpty,
           let rgb = foreground.usingColorSpace(.sRGB),
           0.21 * rgb.redComponent + 0.72 * rgb.greenComponent + 0.07 * rgb.blueComponent > 0.6 {
            let contrastShadow = NSShadow()
            contrastShadow.shadowColor = NSColor.black.withAlphaComponent(0.30 * coreOpacity)
            contrastShadow.shadowBlurRadius = 0.9
            contrastShadow.shadowOffset = NSSize(width: 0, height: -0.5)
            shadow = contrastShadow
        } else {
            shadow = nil
        }
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
                     font: .systemFont(ofSize: 12), color: foreground, shadow: shadow)
        }
        for (index, item) in readouts.enumerated() {
            let width = widths[item.id] ?? 22
            drawText(item.top, x: x, y: rowY, width: width,
                     font: item.pairedValues ? rateFont : valueFont, color: foreground, shadow: shadow)
            drawText(item.bottom, x: x, y: rowY + 11, width: width,
                     font: item.pairedValues ? rateFont : labelFont,
                     color: item.pairedValues ? foreground : secondary, shadow: shadow)
            x += width
            if index < readouts.count - 1 {
                secondary.withAlphaComponent(0.22).setFill()
                NSRect(x: x + (readoutGap - 0.5) / 2, y: (bounds.height - 14) / 2, width: 0.5, height: 14).fill()
                x += readoutGap
            }
        }
    }

    private func drawCoreBackground() {
        guard coreOpacity > 0, !coreColumns.isEmpty, bounds.width > 8,
              let context = NSGraphicsContext.current?.cgContext else { return }
        let scale = window?.backingScaleFactor ?? 2
        func align(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        let pixel = 1 / scale
        let inset: CGFloat = 3
        let availableWidth = bounds.width - 2 * inset
        let count = CGFloat(coreColumns.count)
        let gap = min(1.5, availableWidth / count / 4)
        let columnWidth = (availableWidth - gap * (count - 1)) / count
        let top = align(bounds.midY - bounds.height / 4)
        let bottom = align(bounds.midY + bounds.height / 4)
        let height = bottom - top
        let rows = min(7, (Int((height * scale).rounded()) + 1) / 2)
        guard rows > 0 else { return }
        let rowHeight = (height + pixel) / CGFloat(rows)
        let loads = displayedCoreLoads(at: ProcessInfo.processInfo.systemUptime)
        let levels = coreColumns.map { CGFloat(rows) * min(100, max(0, loads[$0.index])) / 100 }
        let slot = NSColor(srgbRed: 0.03, green: 0.05, blue: 0.08, alpha: 0.16 * coreOpacity).cgColor

        func coverage(at index: Int, cell: Int) -> CGFloat {
            guard levels.indices.contains(index), cell >= 0 else { return 0 }
            return min(1, max(0, levels[index] - CGFloat(cell)))
        }

        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: CGRect(x: inset, y: top, width: availableWidth, height: height))
        for (index, column) in coreColumns.enumerated() {
            let leading = inset + CGFloat(index) * (columnWidth + gap)
            let x = align(leading)
            let width = align(leading + columnWidth) - x
            guard width >= pixel else { continue }
            let level = levels[index]
            let (base, peak) = column.warm ? Self.warmLED : Self.coolLED
            for cell in 0..<rows {
                let row = CGFloat(rows - 1 - cell)
                let y = align(top + row * rowHeight)
                let lower = align(top + (row + 1) * rowHeight) - pixel
                let rect = CGRect(x: x, y: y, width: width, height: lower - y)
                let radius = min(pixel, rect.height / 2, width / 2)
                let shape = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
                context.setFillColor(slot)
                context.addPath(shape)
                context.fillPath()

                let lit = coverage(at: index, cell: cell)
                // A lit LED reflects softly into its neighbouring sockets.
                let neighbours = max(coverage(at: index, cell: cell - 1),
                                     0.7 * coverage(at: index - 1, cell: cell),
                                     0.7 * coverage(at: index + 1, cell: cell))
                let reflection = (1 - lit) * neighbours
                if reflection > 0 {
                    context.setFillColor(base.withAlphaComponent(coreOpacity * reflection * 0.16).cgColor)
                    context.addPath(shape)
                    context.fillPath()
                }
                guard lit > 0 else { continue }
                let highlight = max(0, 1 - abs(level - CGFloat(cell + 1)))
                let rise = CGFloat(cell) / CGFloat(max(1, rows - 1))
                let color = base.blended(withFraction: highlight, of: peak) ?? base
                let halo = rect.insetBy(dx: -0.55 * pixel, dy: -0.55 * pixel)
                context.setFillColor(color.withAlphaComponent(coreOpacity * lit * (0.07 + 0.10 * highlight)).cgColor)
                context.addPath(CGPath(roundedRect: halo, cornerWidth: radius + pixel / 2,
                                       cornerHeight: radius + pixel / 2, transform: nil))
                context.fillPath()
                context.setFillColor(color.withAlphaComponent(coreOpacity * lit * (0.43 + 0.10 * rise + 0.17 * highlight)).cgColor)
                context.addPath(shape)
                context.fillPath()
            }
        }
    }

    private func drawText(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat,
                          font: NSFont, color: NSColor, shadow: NSShadow?) {
        // Both rows share the same column centre and fixed row centres. Centre
        // each font line vertically so smaller labels do not drift to the top.
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let frame = NSRect(x: x, y: y + (12 - lineHeight) / 2, width: width, height: lineHeight)
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        attributes[.shadow] = shadow
        (text as NSString).draw(in: frame, withAttributes: attributes)
    }
}
