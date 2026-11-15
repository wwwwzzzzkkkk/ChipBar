/// A display-only summary of paired-peer connectivity. Never exposes
/// commands, writes simulation state or changes the encrypted wire format.
enum ClusterConnectionStatus: Equatable {
    case pairingRequired
    case sharingOff
    case discovering
    case waitingForData
    case online
    case offline

    static func resolve(sharingEnabled: Bool, hasTrustedPeer: Bool,
                        hasNearbyPeer: Bool, onlinePeerCount: Int,
                        hasReceivedRemoteTelemetry: Bool) -> Self {
        guard sharingEnabled else {
            return hasTrustedPeer ? .sharingOff : .pairingRequired
        }
        if onlinePeerCount > 0 { return .online }
        if hasReceivedRemoteTelemetry { return .offline }
        if hasNearbyPeer { return .waitingForData }
        return .discovering
    }

    var symbol: String {
        switch self {
        case .pairingRequired: return "person.crop.circle.badge.plus"
        case .sharingOff: return "pause.circle"
        case .discovering: return "magnifyingglass"
        case .waitingForData: return "clock.arrow.circlepath"
        case .online: return "checkmark.circle.fill"
        case .offline: return "wifi.slash"
        }
    }

    var title: String {
        switch self {
        case .pairingRequired:
            return ChipBarLocale.choose("Pair another Mac", "等待设备配对")
        case .sharingOff:
            return ChipBarLocale.choose("Sharing disabled", "未开启共享")
        case .discovering:
            return ChipBarLocale.choose("Searching for Macs", "正在搜索附近的 Mac")
        case .waitingForData:
            return ChipBarLocale.choose("Waiting for telemetry", "等待远端数据")
        case .online:
            return ChipBarLocale.choose("Connected", "已连接")
        case .offline:
            return ChipBarLocale.choose("Peer offline", "设备离线")
        }
    }

    var hint: String {
        switch self {
        case .pairingRequired:
            return ChipBarLocale.choose("Open Cluster on both Macs to discover and pair a device.",
                                        "请在两台 Mac 打开计算集群并完成配对。")
        case .sharingOff:
            return ChipBarLocale.choose("Monitoring sharing is paused. Enable it to receive peer data.",
                                        "监控共享已暂停，开启共享后才能接收远端数据。")
        case .discovering:
            return ChipBarLocale.choose("Searching… Check that the other Mac has ChipBar open.",
                                        "正在搜索，请确认另一台 Mac 也已打开 ChipBar。")
        case .waitingForData:
            return ChipBarLocale.choose("Connected to a nearby Mac. Waiting for approval or samples.",
                                        "已发现 Mac，正在等待授权或有效采样。")
        case .online:
            return ChipBarLocale.choose("Read-only monitoring is active.", "只读监控已连接。")
        case .offline:
            return ChipBarLocale.choose("The paired Mac is offline or no longer sending telemetry.",
                                        "已配对设备离线或不再发送监控数据。")
        }
    }
}
