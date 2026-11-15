import Foundation
import Testing
@testable import ChipBarCore

struct OpenFASTProgressParsingTests {
    @Test func parsesExactPrimaryInputTMaxOnly() {
        let input = """
        ----- SIMULATION CONTROL -----------------------------
        700.0     TMax          - Total run time [s]
        0.003125  DT            - Simulation time step [s]
        0.05      DT_Out        - Output interval [s]
        5000.0    NotTMax       - Unrelated variable
        """
        #expect(OpenFASTProgressParsing.tMax(in: input) == 700)
        #expect(OpenFASTProgressParsing.tMax(in: "INVALID TMax\n100 NotTMax\n") == nil)
        #expect(OpenFASTProgressParsing.tMax(in: "0 TMax\n") == nil)
    }

    @Test func readsOnlyCompleteDataRows() {
        let output = """
        Output from OpenFAST
        Time RotSpeed PtfmPitch
        (s) (rpm) (deg)
             0.0000  1.2 0.0
           350.0000  1.2 0.0
           475.0000  1.3 0.0
        """
        #expect(OpenFASTProgressParsing.latestTime(in: output + "\n") == 475)
        #expect(OpenFASTProgressParsing.latestTime(in: output + "\n56") == 475)
        #expect(OpenFASTProgressParsing.latestTime(in: "Time Power\n(s) (W)\n") == nil)
    }

    @Test func truncatedTailDoesNotUsePartialFirstLine() {
        let tail = "9999.0000 10.0\n350.0000 12.0\n"
        #expect(OpenFASTProgressParsing.latestTime(in: tail, truncatedStart: true) == 350)
    }

    @Test func parsesActualOpenFASTSttsTimeFromCapturedLog() {
        let log = """
        OpenFAST v4.2.0
        Time: 70 of 700 seconds. Estimated final completion at 16:31:27.
        warning: no error
        Timestep: 350 of 700 seconds. Estimated final completion at 16:32:01.
        """
        let result = OpenFASTProgressParsing.latestStatus(in: log)
        #expect(result?.current == 350)
        #expect(result?.maximum == 700)
        #expect(OpenFASTProgressParsing.fraction(
            current: result?.current, maximum: result?.maximum) == 0.5)
    }

    @Test func carriageReturnsAndTruncatedTailsAreHandled() {
        let log = "some unrelated output\rTime: 20 of 100 seconds.\rTime: 70 of 100 seconds.\r"
        #expect(OpenFASTProgressParsing.latestStatus(in: log)?.current == 70)
        #expect(OpenFASTProgressParsing.latestStatus(
            in: "partial line\nTime: 80 of 100 seconds.\n",
            truncatedStart: true)?.current == 80)
    }

    @Test func rejectsMisleadingErrorsAndInvalidStatusLines() {
        #expect(OpenFASTProgressParsing.latestStatus(
            in: "OpenFAST encountered an error at simulation time 7.96 of 600 seconds.\n") == nil)
        #expect(OpenFASTProgressParsing.latestStatus(
            in: "Time: 1800 of 100 seconds.\n") == nil)
        #expect(OpenFASTProgressParsing.latestStatus(
            in: "Time: nan of 100 seconds.\n") == nil)
        #expect(OpenFASTProgressParsing.latestStatus(
            in: "Time: 1 of 0 seconds.\n") == nil)
        #expect(OpenFASTProgressParsing.latestStatus(
            in: "Random Time: 80 of 100 seconds.\n") == nil)
    }

    @Test func progressAndETAAreBasedOnValidSimulationTime() {
        #expect(OpenFASTProgressParsing.fraction(current: 350, maximum: 700) == 0.5)
        #expect(OpenFASTProgressParsing.remainingSeconds(
            current: 350, maximum: 700, elapsed: 120) == 120)
        #expect(OpenFASTProgressParsing.fraction(current: 701, maximum: 700) == nil)
        #expect(OpenFASTProgressParsing.fraction(current: 10, maximum: 0) == nil)
        #expect(OpenFASTProgressParsing.fraction(current: .nan, maximum: 700) == nil)
        #expect(OpenFASTProgressParsing.remainingSeconds(
            current: 35, maximum: 700, elapsed: 100) == nil)
    }

    @Test func v361WireDecodesV360TaskPayload() throws {
        let legacy = Data("""
        {"id":"case-001","title":"OC4 Semi","state":"running","progress":0.42}
        """.utf8)
        let task = try JSONDecoder().decode(ClusterTaskReadout.self, from: legacy)
        #expect(task.progress == 0.42)
        #expect(task.remainingSeconds == nil)
        #expect(task.currentSimTime == nil)
        #expect(task.progressSource == nil)

        let extended = ClusterTaskReadout(id: "case-001", title: "OC4",
            state: "运行中", progress: 0.5, currentSimTime: 350,
            targetSimTime: 700, elapsedSeconds: 120, remainingSeconds: 120,
            progressSource: "log")
        let restored = try JSONDecoder().decode(ClusterTaskReadout.self,
            from: JSONEncoder().encode(extended))
        #expect(restored == extended)
    }
}
