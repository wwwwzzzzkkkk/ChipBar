import Foundation
import Testing
@testable import ChipBarCore

struct BoundedCommandTests {
    @Test func drainsBothPipesAndPreservesNonzeroStatus() throws {
        let result = try BoundedCommand().run("/bin/sh", ["-c", "printf '{\"temperature\":44}'; printf 'diagnostic' >&2; exit 8"])
        #expect(result.status == 8)
        #expect(String(decoding: result.data, as: UTF8.self) == #"{"temperature":44}"#)
        #expect(result.diagnostic == "diagnostic")
    }
    @Test func timeoutKillsUnresponsiveProcess() {
        let start = Date()
        #expect(throws: CommandError.timeout) { try BoundedCommand().run("/bin/sleep", ["30"], timeout: 0.1) }
        #expect(Date().timeIntervalSince(start) < 3)
    }
    @Test func cancellationPreventsFurtherCommands() async throws {
        let runner = BoundedCommand()
        let task = Task.detached { try runner.run("/bin/sleep", ["30"]) }
        try await Task.sleep(nanoseconds: 100_000_000)
        runner.cancel()
        do { _ = try await task.value; Issue.record("Cancellation returned a result") }
        catch { #expect(error as? CommandError == .cancelled) }
        #expect(throws: CommandError.cancelled) { try runner.run("/usr/bin/true", []) }
    }
    @Test func oversizedOutputIsBounded() {
        #expect(throws: CommandError.outputLimit) { try BoundedCommand().run("/usr/bin/yes", [], timeout: 2) }
    }
    @Test func missingExecutableDoesNotPoisonNextRun() throws {
        let runner = BoundedCommand()
        #expect(throws: (any Error).self) { try runner.run("/nonexistent/chipbar-smartctl", []) }
        #expect(try runner.run("/usr/bin/true", []).status == 0)
    }
}
