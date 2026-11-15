import Foundation

/// Pure, testable parsing for a *running* OpenFAST process. Reading a result
/// file alone is never proof that a simulation is running or completed.
public enum OpenFASTProgressParsing {
    /// Finds the first numeric TMax entry in a primary .fst input.
    /// Comments/section headings and similarly named parameters are ignored.
    public static func tMax(in fst: String) -> Double? {
        for rawLine in fst.split(whereSeparator: \.isNewline) {
            let fields = rawLine.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2,
                  fields[1].lowercased() == "tmax",
                  let time = Double(fields[0]),
                  time.isFinite, time > 0 else { continue }
            return time
        }
        return nil
    }

    /// The first column in an ASCII OpenFAST .out is Time [s]. Process
    /// complete lines only; the final line can be mid-write during sampling.
    /// 'tail' may start in the middle of a line if the file is large.
    public static func latestTime(in tail: String, truncatedStart: Bool = false) -> Double? {
        let lines = tail.components(separatedBy: .newlines)
        guard lines.count >= 2 else { return nil }
        // Last component is either empty (terminated line) or a partial row.
        let complete = lines.dropLast()
        let candidates = truncatedStart ? complete.dropFirst() : complete[...]
        for line in candidates.reversed() {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2,
                  let time = Double(fields[0]),
                  let second = Double(fields[1]),
                  time.isFinite, second.isFinite, time >= 0 else { continue }
            return time
        }
        return nil
    }


    /// The terminal status reported by OpenFAST's SttsTime setting.
    /// Do not confuse this with fatal-error messages containing
    /// "simulation time X of Y seconds" elsewhere in a log.
    public struct StatusReading: Equatable, Sendable {
        public let current: Double
        public let maximum: Double
        public init(current: Double, maximum: Double) {
            self.current = current
            self.maximum = maximum
        }
    }

    private static let statusPattern: NSRegularExpression = {
        // Examples: "Time: 70 of 100 seconds." and
        // "Timestep: 3 of 60 seconds. Estimated final completion ..."
        let pattern = #"(?i)^\s*(?:Time|Timestep)\s*:\s*(\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)\s+of\s+(\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)\s+seconds\b"#
        return try! NSRegularExpression(pattern: pattern)
    }()

    /// Read only complete status messages from a bounded tail. OpenFAST can
    /// overwrite its terminal status line using CR rather than LF.
    public static func latestStatus(in tail: String,
                                    truncatedStart: Bool = false) -> StatusReading? {
        let lines = tail.split(omittingEmptySubsequences: false,
                               whereSeparator: \.isNewline)
        let candidates = truncatedStart ? lines.dropFirst() : lines[...]
        for rawLine in candidates.reversed() {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            // Do not parse terminal escape codes or arbitrary text.
            guard !line.isEmpty, line.count <= 512 else { continue }
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = statusPattern.firstMatch(in: line,
                                                       options: [], range: range),
                  match.range.location == 0,
                  let cRange = Range(match.range(at: 1), in: line),
                  let mRange = Range(match.range(at: 2), in: line),
                  let current = Double(line[cRange]),
                  let maximum = Double(line[mRange]),
                  fraction(current: current, maximum: maximum) != nil else { continue }
            return StatusReading(current: current, maximum: maximum)
        }
        return nil
    }

    public static func fraction(current: Double?, maximum: Double?) -> Double? {
        guard let current, let maximum, current.isFinite, maximum.isFinite,
              maximum > 0, current >= 0, current <= maximum * 1.0001 else { return nil }
        return min(1, max(0, current / maximum))
    }

    /// This is an indicative ETA, not a wall-clock completion guarantee.
    /// Do not infer it from CPU usage or the existence/size of an .outb file.
    public static func remainingSeconds(current: Double?, maximum: Double?,
                                        elapsed: Double?) -> Double? {
        guard let fraction = fraction(current: current, maximum: maximum),
              let elapsed, elapsed.isFinite, elapsed >= 20,
              fraction >= 0.1, fraction < 1 else { return nil }
        let estimate = elapsed * (1 - fraction) / fraction
        guard estimate.isFinite, estimate >= 0, estimate <= 7 * 24 * 3600 else {
            return nil
        }
        return estimate
    }
}
