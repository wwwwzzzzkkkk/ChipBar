import CoreGraphics

enum DisclosurePanelSizing {
    /// The return trip must use the cached home height. Measuring only after
    /// the page slides would serialize two separate animations and stutter.
    static func navigationHeight(enteringSettings: Bool,
                                 currentHeight: CGFloat,
                                 homeHeight: CGFloat?,
                                 settingsHeight: CGFloat?,
                                 maximumHeight: CGFloat) -> CGFloat {
        let proposal = enteringSettings
            ? (settingsHeight ?? maximumHeight)
            : (homeHeight ?? currentHeight)
        return min(maximumHeight, max(250, proposal))
    }

    /// Match the actual AppKit and SwiftUI cubic ease-in-out curve when a
    /// disclosure is interrupted halfway through; smoothstep is subtly
    /// different and can create a 2–4 pt positional hitch on reversal.
    static func easeInOutProgress(_ time: Double) -> Double {
        let x = max(0, min(1, time))
        if x == 0 || x == 1 { return x }
        var u = x
        for _ in 0..<6 {
            let inv = 1 - u
            let curveX = 3 * inv * inv * u * 0.42
                + 3 * inv * u * u * 0.58 + u * u * u
            let derivative = 3 * inv * inv * 0.42
                + 6 * inv * u * (0.58 - 0.42) + 3 * u * u * 0.42
            guard derivative > 0.0001 else { break }
            u = max(0, min(1, u - (curveX - x) / derivative))
        }
        return 3 * (1 - u) * u * u + u * u * u
    }

    /// Recover the stable fully-collapsed document height from the last
    /// settled layout. While a panel animation is in progress, keep reusing
    /// that baseline: measuredHeight intentionally does not track each frame.
    static func collapsedDocumentHeight(measuredHeight: CGFloat, applications: Double,
                                        ssd: Double, ssdDetailsHeight: CGFloat) -> CGFloat {
        max(0, measuredHeight - CGFloat(applications) * 104
            - CGFloat(ssd) * max(0, ssdDetailsHeight))
    }

    /// Interruption-safe destination. Retarget directly from the same baseline
    /// rather than subtracting from a stale previous window/document height.
    static func expandedDocumentHeight(collapsedHeight: CGFloat, applications: Double,
                                       ssd: Double, ssdDetailsHeight: CGFloat) -> CGFloat {
        max(250, collapsedHeight + CGFloat(applications) * 104
            + CGFloat(ssd) * max(0, ssdDetailsHeight))
    }

    static func targetHeight(documentHeight: CGFloat, contentHeightDelta: CGFloat, maximumHeight: CGFloat) -> CGFloat {
        let finalDocumentHeight = ceil(documentHeight + contentHeightDelta)
        return min(maximumHeight, max(250, finalDocumentHeight))
    }
}
