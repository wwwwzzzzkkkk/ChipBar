import AppKit

/// Resolve app icons only on first appearance, never per sensor frame.
@MainActor enum ApplicationIconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for path: String) -> NSImage {
        if let image = cache[path] { return image }
        let image = NSWorkspace.shared.icon(forFile: path)
        // Keep memory bounded during long-lived menu-bar sessions.
        if cache.count >= 100 { cache.removeAll(keepingCapacity: true) }
        cache[path] = image
        return image
    }
}
