import Foundation

public struct CommandOutput: Sendable {
    public let data: Data
    public let diagnostic: String
    public let status: Int32
}

public enum CommandError: Error, LocalizedError, Equatable {
    case cancelled, timeout, outputLimit
    public var errorDescription: String? {
        switch self {
        case .cancelled: return "读取已取消"
        case .timeout: return "读取超时；请检查硬盘盒连接。"
        case .outputLimit: return "程序输出超过限制。"
        }
    }
}

/// Serial worker with bounded pipe drains. Never call run on the UI thread.
public final class BoundedCommand: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var current: Process?
    public init() {}

    public func cancel(wait: Bool = false) {
        lock.lock(); cancelled = true
        let process = current
        if let process, process.isRunning { process.terminate() }
        lock.unlock()
        if wait, let process {
            let deadline = ProcessInfo.processInfo.systemUptime + 0.2
            while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { usleep(10_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    public func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 5) throws -> CommandOutput {
        let process = Process()
        let stdout = Pipe(), stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout; process.standardError = stderr
        lock.lock()
        guard !cancelled else { lock.unlock(); throw CommandError.cancelled }
        do { try process.run() } catch { lock.unlock(); throw error }
        current = process
        lock.unlock()
        defer {
            lock.lock(); current = nil; lock.unlock()
            try? stdout.fileHandleForReading.close(); try? stderr.fileHandleForReading.close()
        }
        let out = CommandCapture(limit: 1_048_576), err = CommandCapture(limit: 4096)
        // Nonblocking POSIX reads keep timeouts bounded even if a child retains a pipe.
        for pipe in [stdout, stderr] {
            let fd = pipe.fileHandleForReading.fileDescriptor
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        }
        func drain(_ pipe: Pipe, _ capture: CommandCapture) {
            var bytes = [UInt8](repeating: 0, count: 16_384)
            for _ in 0..<64 {
                let count = read(pipe.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
                guard count > 0 else { break }
                capture.append(Data(bytes.prefix(count)))
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var failure: CommandError?
        while process.isRunning {
            drain(stdout, out); drain(stderr, err)
            lock.lock(); let stopped = cancelled; lock.unlock()
            if stopped { failure = .cancelled }
            else if ProcessInfo.processInfo.systemUptime >= deadline { failure = .timeout }
            else if out.exceeded { failure = .outputLimit }
            if failure != nil {
                process.terminate()
                usleep(100_000)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                break
            }
            usleep(20_000)
        }
        process.waitUntilExit()
        drain(stdout, out); drain(stderr, err)
        lock.lock(); let stopped = cancelled; lock.unlock()
        if stopped { throw CommandError.cancelled }
        if let failure { throw failure }
        if out.exceeded { throw CommandError.outputLimit }
        return CommandOutput(data: out.data, diagnostic: String(decoding: err.data, as: UTF8.self), status: process.terminationStatus)
    }
}

private final class CommandCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var buffer = Data()
    private var overflow = false
    init(limit: Int) { self.limit = limit }
    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        let remaining = limit - buffer.count
        buffer.append(data.prefix(remaining))
        overflow = overflow || data.count > remaining
    }
    var data: Data { lock.lock(); defer { lock.unlock() }; return buffer }
    var exceeded: Bool { lock.lock(); defer { lock.unlock() }; return overflow }
}
