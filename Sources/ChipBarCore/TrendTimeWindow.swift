import Foundation

/// A stable, real-time 10-minute domain for the power chart.
/// The chart must not stretch a few seconds of startup samples across
/// the entire width while claiming to show the last 10 minutes.
public struct TrendTimeWindow {
    public static let duration: TimeInterval = 600

    public let end: Date
    public var start: Date { end.addingTimeInterval(-Self.duration) }
    public var midpoint: Date { end.addingTimeInterval(-Self.duration / 2) }
    public var ticks: [Date] { [start, midpoint, end] }

    public init(endingAt end: Date) { self.end = end }

    /// Returns a visible 0...1 coordinate, not an extrapolated fraction.
    public func fraction(for date: Date) -> Double? {
        let fraction = date.timeIntervalSince(start) / Self.duration
        return (0...1).contains(fraction) ? fraction : nil
    }

    /// Explicit local 24-hour clock. Minute/second labels like "07:44"
    /// were ambiguous and could be mistaken for 07:44 AM.
    public static func clockLabel(_ date: Date,
                                  timeZone: TimeZone = .autoupdatingCurrent) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
