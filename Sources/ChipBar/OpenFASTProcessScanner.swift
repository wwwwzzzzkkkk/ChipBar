import Foundation
import Darwin
import ChipBarCore

/// Read-only OpenFAST process observer. This actor never creates a Process,
/// runs a shell, modifies a simulation file, or controls a calculation.
/// It only enumerates same-user PIDs and reads bounded input/output bytes.
actor OpenFASTProcessScanner {
    static let shared = OpenFASTProcessScanner()

    private static let maximumProcesses = 12
    private static let maximumArgumentsBytes = 131_072
    private static let maximumInputBytes = 1_048_576
    private static let tailBytes = 16_384

    func scan(now: Date = Date()) -> [ClusterTaskReadout] {
        autoreleasepool {
            let capacity = min(16_384, max(256, Int(proc_listallpids(nil, 0)) + 64))
            var pids = [Int32](repeating: 0, count: capacity)
            let count = pids.withUnsafeMutableBytes {
                proc_listallpids($0.baseAddress, Int32($0.count))
            }
            guard count > 0 else { return [] }
            var result: [ClusterTaskReadout] = []
            for pid in pids.prefix(min(Int(count), capacity)) where pid > 0 {
                guard isOpenFASTProcess(pid: pid) else { continue }
                guard let item = inspect(pid: pid, now: now) else { continue }
                result.append(item)
                if result.count >= Self.maximumProcesses { break }
            }
            return result.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }

    private func isOpenFASTProcess(pid: Int32) -> Bool {
        var name = [CChar](repeating: 0, count: 256)
        let length = proc_name(pid, &name, UInt32(name.count))
        guard length > 0 else { return false }
        let processName = String(cString: name).lowercased()
        return processName == "openfast" || processName.hasPrefix("openfast-")
            || processName.hasPrefix("openfast_")
    }

    private func inspect(pid: Int32, now: Date) -> ClusterTaskReadout? {
        var bsd = proc_bsdinfo()
        let length = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, length) == length else {
            return nil
        }
        let birth = Double(bsd.pbi_start_tvsec) +
            Double(bsd.pbi_start_tvusec) / 1_000_000
        guard birth > 0, now.timeIntervalSince1970 >= birth else { return nil }
        let elapsed = now.timeIntervalSince1970 - birth
        let args = Self.arguments(pid: pid)
        let fstArg = args.first {
            $0.lowercased().hasSuffix(".fst") && !$0.hasPrefix("-")
        }
        let inputURL = fstArg.flatMap { Self.resolveInput($0, pid: pid) }
        let title = inputURL?.deletingPathExtension().lastPathComponent
            ?? (fstArg.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent })
            ?? "OpenFAST"
        // A PID can be reused; include its process birth time in the task ID.
        let taskID = "openfast-\(pid)-\(Int(birth))"
        let inputMaximum = inputURL.flatMap(Self.readTMax)
        let logStatus = inputURL.flatMap {
            Self.readLatestStatus(fst: $0, pid: pid,
                                  processBirth: birth, now: now)
        }
        // Logs for another run must not override the current .fst target.
        let verifiedLog = logStatus.flatMap { status -> OpenFASTProgressParsing.StatusReading? in
            if let inputMaximum,
               abs(status.maximum - inputMaximum) > max(0.01, inputMaximum * 0.001) {
                return nil
            }
            return status
        }
        let textTime = inputURL.flatMap {
            Self.readLatestSimulationTime(fst: $0, processBirth: birth, now: now)
        }
        let maximum = inputMaximum ?? verifiedLog?.maximum
        // When BOTH sources are available, use the later actual simulation
        // time: OpenFAST stdout status can update far less often than .out.
        let logTime = verifiedLog?.current
        let validText = OpenFASTProgressParsing.fraction(
            current: textTime, maximum: maximum) != nil ? textTime : nil
        let useText: Bool
        if let validText {
            useText = logTime.map { validText > $0 } ?? true
        } else {
            useText = false
        }
        let simulationTime = useText ? validText : logTime
        let fraction = OpenFASTProgressParsing.fraction(
            current: simulationTime, maximum: maximum)
        let remaining = OpenFASTProgressParsing.remainingSeconds(
            current: simulationTime, maximum: maximum, elapsed: elapsed)
        let source: String? = fraction == nil ? nil : (useText ? "out" : "log")
        return ClusterTaskReadout(
            id: taskID, title: title.isEmpty ? "OpenFAST" : title,
            state: "运行中", progress: fraction,
            currentSimTime: fraction == nil ? nil : simulationTime,
            targetSimTime: maximum, elapsedSeconds: elapsed,
            remainingSeconds: remaining, progressSource: source)
    }

    private static func readTMax(_ input: URL) -> Double? {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: input.path),
              let size = (attrs[.size] as? NSNumber)?.intValue,
              size > 0, size <= maximumInputBytes,
              let raw = try? Data(contentsOf: input, options: [.mappedIfSafe]),
              let text = String(data: raw, encoding: .utf8) else { return nil }
        return OpenFASTProgressParsing.tMax(in: text)
    }

    private static func readLatestSimulationTime(
        fst: URL, processBirth: TimeInterval, now: Date
    ) -> Double? {
        let out = fst.deletingPathExtension().appendingPathExtension("out")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: out.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value,
              size > 0,
              let modified = attrs[.modificationDate] as? Date,
              // Never display a stale output from a previous run.
              modified.timeIntervalSince1970 >= processBirth - 2,
              now.timeIntervalSince(modified) >= -5,
              now.timeIntervalSince(modified) < 120 else { return nil }
        guard let tail = readTail(of: out, length: size) else { return nil }
        return OpenFASTProgressParsing.latestTime(
            in: tail.text, truncatedStart: tail.truncated)
    }

    /// Read only the last few KiB of a result or log file.
    private static func readTail(of url: URL, length: UInt64)
        -> (text: String, truncated: Bool)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let offset = length > UInt64(tailBytes) ? length - UInt64(tailBytes) : 0
        guard (try? handle.seek(toOffset: offset)) != nil,
              let bytes = try? handle.read(upToCount: tailBytes),
              !bytes.isEmpty else { return nil }
        return (String(decoding: bytes, as: UTF8.self), offset > 0)
    }

    private static func readLatestStatus(fst: URL, pid: Int32,
                                         processBirth: TimeInterval,
                                         now: Date) -> OpenFASTProgressParsing.StatusReading? {
        let root = fst.deletingPathExtension()
        var candidates: [URL] = []
        // A redirected stdout/stderr file can have any filename. Do not
        // intercept live pipes or attach to the simulation process.
        for fd in [STDOUT_FILENO, STDERR_FILENO] {
            if let path = redirectedFilePath(pid: pid, fd: fd) {
                candidates.append(URL(fileURLWithPath: path))
            }
        }
        // If stdout is piped to tee, the input-associated log is discoverable.
        for suffix in ["log", "stdout.log", "run.log", "openfast.log", "out.log"] {
            candidates.append(URL(fileURLWithPath: root.path + "." + suffix))
        }
        var seen = Set<String>()
        for url in candidates {
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted else { continue }
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let length = (attributes[.size] as? NSNumber)?.uint64Value,
                  length > 0,
                  let modified = attributes[.modificationDate] as? Date,
                  modified.timeIntervalSince1970 >= processBirth - 2,
                  now.timeIntervalSince(modified) >= -5,
                  now.timeIntervalSince(modified) < 300,
                  let tail = readTail(of: url, length: length),
                  let status = OpenFASTProgressParsing.latestStatus(
                    in: tail.text, truncatedStart: tail.truncated)
            else { continue }
            return status
        }
        return nil
    }

    private static func redirectedFilePath(pid: Int32, fd: Int32) -> String? {
        var info = vnode_fdinfowithpath()
        let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        guard proc_pidfdinfo(pid, fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else {
            return nil
        }
        let chars = withUnsafeBytes(of: info.pvip.vip_path) {
            Array($0.prefix { $0 != 0 })
        }
        guard !chars.isEmpty, let path = String(bytes: chars, encoding: .utf8),
              path.hasPrefix("/") else { return nil }
        return path
    }

    private static func resolveInput(_ input: String, pid: Int32) -> URL? {
        guard input.count <= 2048, !input.isEmpty else { return nil }
        let absolute: URL
        if input.hasPrefix("/") {
            absolute = URL(fileURLWithPath: input)
        } else if let cwd = workingDirectory(pid: pid) {
            absolute = URL(fileURLWithPath: cwd, isDirectory: true)
                .appendingPathComponent(input)
        } else {
            // Never resolve the other process's relative .fst against the
            // current ChipBar working directory: that can display wrong data.
            return nil
        }
        let result = absolute.standardizedFileURL
        guard result.isFileURL,
              FileManager.default.fileExists(atPath: result.path) else {
            return nil
        }
        return result
    }

    private static func workingDirectory(pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let length = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, length) == length else {
            return nil
        }
        let chars = withUnsafeBytes(of: info.pvi_cdir.vip_path) { bytes in
            Array(bytes.prefix { $0 != 0 })
        }
        guard !chars.isEmpty else { return nil }
        return String(bytes: chars, encoding: .utf8)
    }

    /// KERN_PROCARGS2: argc, executable path, zero padding, then argv.
    /// Read only short, valid argument buffers; do not inspect environments.
    private static func arguments(pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var count: size_t = 0
        let sizeResult = mib.withUnsafeMutableBufferPointer {
            sysctl($0.baseAddress, u_int($0.count), nil, &count, nil, 0)
        }
        guard sizeResult == 0, count >= 8, count <= maximumArgumentsBytes
        else { return [] }
        var bytes = [UInt8](repeating: 0, count: Int(count))
        let rc = bytes.withUnsafeMutableBytes { buffer in
            mib.withUnsafeMutableBufferPointer {
                sysctl($0.baseAddress, u_int($0.count), buffer.baseAddress,
                       &count, nil, 0)
            }
        }
        guard rc == 0, count >= 8 else { return [] }
        let length = min(Int(count), bytes.count)
        let argc = bytes.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        guard argc > 0, argc <= 128 else { return [] }
        var cursor = 4
        while cursor < length && bytes[cursor] != 0 { cursor += 1 }
        while cursor < length && bytes[cursor] == 0 { cursor += 1 }
        var items: [String] = []
        for _ in 0..<argc {
            guard cursor < length else { break }
            let start = cursor
            while cursor < length && bytes[cursor] != 0 { cursor += 1 }
            if let arg = String(bytes: bytes[start..<cursor], encoding: .utf8) {
                items.append(arg)
            }
            cursor += 1
        }
        return items
    }
}
