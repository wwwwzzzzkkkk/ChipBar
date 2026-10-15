import Foundation
import Testing
@testable import ChipBarCore

struct SSDTemperatureTests {
    func decode(_ text: String, status: Int32 = 0) throws -> SSDTemperature {
        try SSDTemperature.decode(Data(text.utf8), exitStatus: status)
    }
    func plist(_ object: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
    }

    @Test func actualZHITAIFixture() throws {
        let url = try #require(Bundle.module.url(forResource: "zhitai-tiplus7100s", withExtension: "json", subdirectory: "Fixtures"))
        let sample = try SSDTemperature.decode(Data(contentsOf: url))
        #expect(sample.model == "ZHITAI TiPlus7100s 2TB")
        #expect(sample.composite == 46)
        #expect(sample.sensors == [46, 38])
        #expect(sample.passed == true)
        #expect(sample.criticalWarning == 0)
        #expect(sample.percentageUsed == 0)
    }

    @Test func sparseSensorsAndCompositeAreIndependent() throws {
        let sample = try decode(#"{"nvme_smart_health_information_log":{"temperature_sensors":[null,38,null,0]},"temperature":{"current":44}}"#)
        #expect(sample.composite == 44)
        #expect(sample.sensors == [nil, 38, nil, 0])
        #expect(sample.passed == nil)
        let sensorOnly = try decode(#"{"nvme_smart_health_information_log":{"temperature_sensors":[45,37]}}"#)
        #expect(sensorOnly.composite == nil)
        #expect(sensorOnly.sensors == [45, 37])
    }

    @Test func invalidMetricsDoNotBecomeNumbers() throws {
        let sample = try decode(#"{"nvme_smart_health_information_log":{"temperature":true,"temperature_sensors":["45",null,999,-999,38],"percentage_used":-1},"smart_status":{"passed":1}}"#)
        #expect(sample.composite == nil)
        #expect(sample.sensors == [nil, nil, nil, nil, 38])
        #expect(sample.passed == nil)
        #expect(sample.percentageUsed == nil)
        for invalid in ["not json", "[]", "{}", #"{"temperature":{"current":44}}"#, #"{"nvme_smart_health_information_log":{"temperature":999}}"#] {
            #expect(throws: (any Error).self) { try decode(invalid) }
        }
    }

    @Test func exitBitmaskPreservesHealthWarningsAndPartialRead() throws {
        let json = #"{"nvme_smart_health_information_log":{"temperature":44,"critical_warning":2},"smart_status":{"passed":false}}"#
        for status: Int32 in [8, 16, 32, 64, 128, 248] {
            let sample = try decode(json, status: status)
            #expect(sample.composite == 44)
            #expect(sample.passed == false)
            #expect(sample.criticalWarning == 2)
        }
        #expect(try decode(json, status: 4).partialRead)
        for status: Int32 in [1, 2, 3, 255] {
            #expect(throws: SSDReadError.commandFailed) { try decode(json, status: status) }
        }
        #expect(throws: SSDReadError.permission) {
            try decode(#"{"smartctl":{"exit_status":2,"messages":[{"string":"Open failed: Permission denied"}]}}"#)
        }
    }

    @Test func freshnessRejectsOldAndFutureReadings() throws {
        let date = Date(timeIntervalSince1970: 1000)
        let sample = try SSDTemperature.decode(Data(#"{"nvme_smart_health_information_log":{"temperature":44}}"#.utf8), date: date)
        #expect(sample.isFresh(at: date.addingTimeInterval(90)))
        #expect(!sample.isFresh(at: date.addingTimeInterval(91)))
        #expect(!sample.isFresh(at: date.addingTimeInterval(-1)))
    }

    @Test func discoveryExcludesPartitionsInternalAndVirtualMedia() throws {
        let list = try plist(["AllDisksAndPartitions": [["DeviceIdentifier":"disk4"], ["DeviceIdentifier":"disk4s1"], ["DeviceIdentifier":"disk4"], ["DeviceIdentifier":"disk5;echo x"]]])
        #expect(try ExternalDisk.identifiers(from: list) == ["disk4"])
        var info: [String: Any] = ["DeviceIdentifier":"disk4", "WholeDisk":true, "Internal":false, "VirtualOrPhysical":"Physical", "MediaName":"ZHITAI"]
        let disk = try ExternalDisk.decodeInfo(plist(info), expectedID: "disk4")
        #expect(disk.smartArguments(type: .auto) == ["-j", "-i", "-H", "-A", "-d", "auto", "/dev/disk4"])
        for (key, bad): (String, Any) in [("Internal", true), ("WholeDisk", false), ("VirtualOrPhysical", "Virtual"), ("DeviceIdentifier", "disk5")] {
            var invalid = info; invalid[key] = bad
            #expect(throws: SSDReadError.invalidDevice) { try ExternalDisk.decodeInfo(plist(invalid), expectedID: "disk4") }
        }
        info.removeValue(forKey: "Internal")
        #expect(throws: SSDReadError.invalidDevice) { try ExternalDisk.decodeInfo(plist(info), expectedID: "disk4") }
    }

    @Test func probeReconnectRenumberAndPermissionFailureReplaceOldReadings() throws {
        func probe(id: String?, denied: Bool = false, sudo: Bool = false) throws -> SSDProbeResult {
            try ExternalSSDProbe.read(path: "/opt/homebrew/bin/smartctl", type: .auto, useSudo: sudo) { executable, args in
                let data: Data
                if args.first == "list" {
                    data = try plist(["AllDisksAndPartitions": id.map { [["DeviceIdentifier":$0]] } ?? []])
                } else if args.first == "info" {
                    data = try plist(["DeviceIdentifier":id!, "Internal":false, "WholeDisk":true, "VirtualOrPhysical":"Physical"])
                } else {
                    #expect(executable == (sudo ? "/usr/bin/sudo" : "/opt/homebrew/bin/smartctl"))
                    if sudo { #expect(Array(args.prefix(3)) == ["-n", "--", "/opt/homebrew/bin/smartctl"]) }
                    #expect(args.last == "/dev/" + id!)
                    data = Data(#"{"nvme_smart_health_information_log":{"temperature":44}}"#.utf8)
                }
                return CommandOutput(data: data, diagnostic: denied && !args.contains("-plist") ? "sudo: a password is required" : "", status: 0)
            }
        }
        #expect(try probe(id: "disk4").readings.first?.temperature?.composite == 44)
        #expect(try probe(id: nil).readings.isEmpty)
        #expect(try probe(id: "disk7").readings.first?.id == "disk7")
        let failed = try probe(id: "disk7", denied: true, sudo: true)
        #expect(failed.readings.first?.temperature == nil)
        #expect(failed.readings.first?.error == SSDReadError.permission.localizedDescription)
    }
}
