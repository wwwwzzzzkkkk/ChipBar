import Testing
import Foundation
@testable import ChipBarCore

struct MetricsTests {
    func decode(_ text: String) throws -> Sample { try Sample.decode(Data(text.utf8)) }

    @Test func testActualM1ProFixture() throws {
        let url = try #require(Bundle.module.url(forResource: "m1-pro", withExtension: "json", subdirectory: "Fixtures"))
        let sample = try Sample.decode(Data(contentsOf: url))
        #expect(sample.chip == "Apple M1 Pro")
        #expect(sample.model == "MacBookPro18,3")
        let total = try #require(sample.total)
        let cpu = try #require(sample.cpu)
        let gpu = try #require(sample.gpu)
        let ane = try #require(sample.ane)
        #expect(abs(total - cpu - gpu - ane) < 0.00001)
        #expect(sample.cpuTemperature != nil)
        #expect(!sample.derivedTotal)
    }

    @Test func testMissingValuesAreNotFabricated() throws {
        let sample = try decode(#"{"cpu_power":2,"gpu_power":null,"temp":{"cpu_temp_avg":null},"soc":{"chip_name":"Future chip"},"unknown":42}"#)
        #expect(sample.cpu == 2)
        #expect(sample.gpu == nil)
        #expect(sample.total == nil)
        #expect(sample.cpuTemperature == nil)
        #expect(sample.chip == "Future chip")
    }

    @Test func testSumRequiresAllThreeComponents() throws {
        let complete = try decode(#"{"cpu_power":2,"gpu_power":3,"ane_power":0}"#)
        #expect(complete.total == 5)
        #expect(complete.derivedTotal)
        #expect(try decode(#"{"cpu_power":2,"gpu_power":3}"#).total == nil)
    }

    @Test func testInvalidAndBooleanValuesAreUnavailable() throws {
        let sample = try decode(#"{"cpu_power":true,"gpu_power":-1,"all_power":2,"temp":{"cpu_temp_avg":0,"gpu_temp_avg":151}}"#)
        #expect(sample.cpu == nil)
        #expect(sample.gpu == nil)
        #expect(sample.cpuTemperature == nil)
        #expect(sample.gpuTemperature == nil)
        #expect(sample.total == 2)
    }

    @Test func testZeroPowerIsAValidReportedReading() throws {
        let sample = try decode(#"{"cpu_power":0,"gpu_power":0,"ane_power":0}"#)
        #expect(sample.total == 0)
        #expect(sample.cpuTemperature == nil)
    }

    @Test func testRejectsInvalidSchemaAndNonJSON() {
        for text in ["{}", "[]", "not json", #"{"soc":{"chip_name":"anything"}}"#, #"{"cpu_power":"5"}"#] {
            #expect(throws: (any Error).self) { _ = try decode(text) }
        }
    }

    @Test func testFragmentedUTF8AndMultipleLines() throws {
        var buffer = LineBuffer()
        let bytes = Array("{\"chip\":\"芯片\"}\n{\"cpu_power\":2}\n".utf8)
        var lines: [Data] = []
        for byte in bytes { lines += try buffer.append(Data([byte])) }
        #expect(lines.count == 2)
        #expect(String(decoding: lines[0], as: UTF8.self) == "{\"chip\":\"芯片\"}")
        let emptyTail = buffer.finish()
        #expect(emptyTail == nil)
        let next = try buffer.append(Data("\n{\"cpu_power\":3}\n{\"cpu_power\":4}".utf8))
        #expect(next.count == 1)
        let tail = buffer.finish()
        let unwrapped = try #require(tail)
        #expect(String(decoding: unwrapped, as: UTF8.self) == "{\"cpu_power\":4}")
    }

    @Test func testBoundedBuffer() throws {
        var buffer = LineBuffer()
        #expect(throws: (any Error).self) { _ = try buffer.append(Data(repeating: 65, count: 1_048_577)) }
        var newlineBuffer = LineBuffer()
        var data = Data(repeating: 65, count: 1_048_577); data.append(10)
        #expect(throws: (any Error).self) { _ = try newlineBuffer.append(data) }
    }
}
