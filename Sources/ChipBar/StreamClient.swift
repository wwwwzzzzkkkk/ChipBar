import Foundation
import ChipBarCore

/// A single long-lived subprocess. Pipe reads and JSON parsing never run on the UI thread.
final class StreamClient {
    private let process = Process()
    private let output = Pipe()
    private let errors = Pipe()
    private let lock = NSLock()
    private var diagnostic = Data()
    private var stopped = false
    private let onSample: (Sample) -> Void
    private let onFailure: (String) -> Void

    init(path: String, interval: Int, onSample: @escaping (Sample) -> Void,
         onFailure: @escaping (String) -> Void) {
        self.onSample = onSample
        self.onFailure = onFailure
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["pipe", "--interval", String(interval), "--soc-info"]
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
    }

    func start() throws {
        try process.run()
        let stderrFinished = DispatchGroup()
        stderrFinished.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { stderrFinished.leave() }
            while true {
                let data = errors.fileHandleForReading.availableData
                if data.isEmpty { break }
                lock.lock()
                diagnostic.append(data)
                if diagnostic.count > 4096 { diagnostic = Data(diagnostic.suffix(4096)) }
                lock.unlock()
            }
        }
        DispatchQueue.global(qos: .utility).async { [self] in
            var lines = LineBuffer()
            var parsingFailure: String?
            do {
                while true {
                    let data = output.fileHandleForReading.availableData
                    if data.isEmpty { break }
                    for line in try lines.append(data) {
                        // Each sample is independently validated. Malformed output triggers recovery,
                        // rather than preserving an apparently live old reading.
                        onSample(try Sample.decode(line))
                    }
                }
                if let tail = lines.finish() { onSample(try Sample.decode(tail)) }
            } catch {
                parsingFailure = error.localizedDescription
                if process.isRunning { process.terminate() }
            }
            process.waitUntilExit()
            stderrFinished.wait()
            lock.lock()
            let cancelled = stopped
            let detail = String(decoding: diagnostic, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            lock.unlock()
            if !cancelled {
                let message = parsingFailure ?? "macmon 已退出（状态 \(process.terminationStatus)）。\(detail.isEmpty ? "请检查该机型是否受支持。" : "\n" + detail)"
                onFailure(message)
            }
            try? output.fileHandleForReading.close()
            try? errors.fileHandleForReading.close()
        }
    }

    func stop(wait: Bool = false) {
        lock.lock(); stopped = true; lock.unlock()
        if process.isRunning {
            process.terminate()
            if wait {
                let deadline = Date().addingTimeInterval(2)
                while process.isRunning && Date() < deadline { usleep(20_000) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                return
            }
            // A wedged helper must not survive quit or accumulate after a restart.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [self] in
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }
}
