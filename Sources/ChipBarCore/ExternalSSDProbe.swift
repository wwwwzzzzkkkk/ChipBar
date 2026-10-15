import Foundation

public struct SSDReading: Identifiable, Sendable {
    public let id: String
    public let name: String
    public var temperature: SSDTemperature?
    public var error: String?

    public init(id: String, name: String, temperature: SSDTemperature? = nil, error: String? = nil) {
        self.id = id; self.name = name; self.temperature = temperature; self.error = error
    }
}

public struct SSDProbeResult: Sendable {
    public let readings: [SSDReading]
    public let status: String
    public init(readings: [SSDReading], status: String) { self.readings = readings; self.status = status }
}

public struct ExternalSSDProbe {
    public static let defaultPaths = ["/opt/homebrew/bin/smartctl", "/usr/local/bin/smartctl",
                                      "/opt/homebrew/sbin/smartctl", "/usr/local/sbin/smartctl"]
    public typealias Run = (String, [String]) throws -> CommandOutput

    /// Rediscover external physical whole disks every round; never persist a disk number.
    public static func read(path: String?, type: SMARTDeviceType, useSudo: Bool, run: Run) throws -> SSDProbeResult {
        let listing = try run("/usr/sbin/diskutil", ["list", "-plist", "external", "physical"])
        guard listing.status == 0 else { throw SSDReadError.invalidDevice }
        let ids = try ExternalDisk.identifiers(from: listing.data)
        var readings: [SSDReading] = []
        for id in ids.prefix(8) {
            do {
                let info = try run("/usr/sbin/diskutil", ["info", "-plist", "/dev/" + id])
                guard info.status == 0 else { throw SSDReadError.invalidDevice }
                let disk = try ExternalDisk.decodeInfo(info.data, expectedID: id)
                do {
                    guard let path else {
                        readings.append(SSDReading(id: id, name: disk.name, error: "未安装 smartctl，温度不可用；空间与读写速度仍可查看。"))
                        continue
                    }
                    let args = disk.smartArguments(type: type)
                    let output = try run(useSudo ? "/usr/bin/sudo" : path, useSudo ? ["-n", "--", path] + args : args)
                    let diagnostic = output.diagnostic.lowercased()
                    if diagnostic.contains("password") || diagnostic.contains("not allowed") || diagnostic.contains("permission denied") || diagnostic.contains("operation not permitted") {
                        throw SSDReadError.permission
                    }
                    let temperature = try SSDTemperature.decode(output.data, exitStatus: output.status)
                    readings.append(SSDReading(id: id, name: disk.name, temperature: temperature))
                } catch is CancellationError { throw CancellationError() }
                catch CommandError.cancelled { throw CommandError.cancelled }
                catch { readings.append(SSDReading(id: id, name: disk.name, error: error.localizedDescription)) }
            } catch is CancellationError { throw CancellationError() }
            catch CommandError.cancelled { throw CommandError.cancelled }
            catch { readings.append(SSDReading(id: id, name: id, error: error.localizedDescription)) }
        }
        let status = ids.isEmpty ? "未连接外接物理磁盘" : ids.count > 8 ? "每轮最多读取 8 块外接磁盘" : "每 30 秒读取 · NVMe SMART"
        return SSDProbeResult(readings: readings, status: status)
    }
}
