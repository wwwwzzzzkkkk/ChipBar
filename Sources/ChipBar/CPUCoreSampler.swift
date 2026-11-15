import Foundation
import Darwin
import Combine

/// Two Mach CPU snapshots are needed for utilization: these values are
/// cumulative ticks since boot, NOT instantaneous processor percentages.
/// CPU indices are logical-processor indices; do not assume P/E core mapping.
struct CPUCoreTickSample: Equatable, Sendable {
    let ticks: [[UInt32]]

    static func usage(previous: Self, current: Self) -> [Double]? {
        guard previous.ticks.count == current.ticks.count, !current.ticks.isEmpty else { return nil }
        return zip(previous.ticks, current.ticks).compactMap { old, new -> Double? in
            guard old.count == Int(CPU_STATE_MAX), new.count == Int(CPU_STATE_MAX) else { return nil }
            let busyIndices = [Int(CPU_STATE_USER), Int(CPU_STATE_SYSTEM), Int(CPU_STATE_NICE)]
            let busy = busyIndices.reduce(UInt64(0)) { value, index in
                value + UInt64(new[index] &- old[index])
            }
            let idle = UInt64(new[Int(CPU_STATE_IDLE)] &- old[Int(CPU_STATE_IDLE)])
            let total = busy + idle
            return total > 0 ? min(100, max(0, 100 * Double(busy) / Double(total))) : 0
        }
    }
}

actor CPUCoreSampler {
    private var previous: CPUCoreTickSample?

    func read() -> [Double]? {
        guard let current = Self.ticks() else { return nil }
        defer { previous = current }
        guard let previous else { return nil }
        return CPUCoreTickSample.usage(previous: previous, current: current)
    }

    private static func ticks() -> CPUCoreTickSample? {
        var count: natural_t = 0
        var buffer: processor_info_array_t?
        var wordCount: mach_msg_type_number_t = 0
        let status = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                         &count, &buffer, &wordCount)
        guard status == KERN_SUCCESS, let buffer else { return nil }
        // Mach allocates this out-of-line buffer; copy the small tick array
        // and release the VM allocation before the next sampling interval.
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: buffer),
                          vm_size_t(Int(wordCount) * MemoryLayout<integer_t>.stride))
        }
        let cores = Int(count)
        let stride = Int(CPU_STATE_MAX)
        guard cores > 0, cores <= 256, Int(wordCount) >= cores * stride else { return nil }
        return CPUCoreTickSample(ticks: (0..<cores).map { index in
            (0..<stride).map { value in
                UInt32(bitPattern: buffer[index * stride + value])
            }
        })
    }
}

/// Model is shared to keep a valid reading if the user briefly enters
/// Settings. Sampling stops when no dashboard view is displaying the chart.
@MainActor final class CPUCoreLoadModel: ObservableObject {
    static let shared = CPUCoreLoadModel()
    @Published private(set) var values: [Double] = []
    @Published private(set) var hasSample = false

    private let sampler = CPUCoreSampler()

    func watch(intervalMillis: Int) async {
        let seconds = Double(min(10_000, max(1_000, intervalMillis))) / 1000
        while !Task.isCancelled {
            if let percentages = await sampler.read() {
                guard !Task.isCancelled else { return }
                values = percentages
                hasSample = true
            }
            do { try await Task.sleep(for: .seconds(seconds)) }
            catch { return }
        }
    }
}
