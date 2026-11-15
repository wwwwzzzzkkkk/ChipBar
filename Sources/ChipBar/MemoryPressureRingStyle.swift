import SwiftUI

/// Memory use is the percentage inside the ring. Its *color* represents
/// macOS memory pressure, which is independent of the used percentage.
/// A high utilization percentage with green pressure is not an alert.
enum MemoryPressureRingStyle {
    enum Tone: Equatable {
        case neutral, green, yellow, red
    }

    static func tone(for level: MemoryPressureLevel) -> Tone {
        switch level {
        case .unknown: return .neutral
        case .normal: return .green
        case .warning: return .yellow
        case .critical: return .red
        }
    }

    static func tint(for level: MemoryPressureLevel) -> Color {
        switch tone(for: level) {
        case .neutral: return .secondary
        case .green: return Color(red: 0.31, green: 0.87, blue: 0.77)
        case .yellow: return .yellow
        case .red: return .red
        }
    }
}
