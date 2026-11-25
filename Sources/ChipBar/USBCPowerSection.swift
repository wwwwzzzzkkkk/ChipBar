import SwiftUI

/// Compact, source-aware display of independently measured USB-C VBUS power.
/// The power bars share ChipBar's cyan/blue palette; link capacity is never
/// presented as an achieved speed.
struct USBCPowerSection: View {
    let snapshot: USBCPowerSnapshot
    @State private var showsOtherPorts = false

    private var active: [USBCPortMeasurement] { snapshot.sourcingPorts }
    private var others: [USBCPortMeasurement] {
        snapshot.ports.filter { !$0.isSourcing }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "cable.connector")
                    .foregroundStyle(Color(red: 0.22, green: 0.76, blue: 0.80))
                Text("USB-C 对外供电").font(.caption.weight(.semibold))
                Spacer(minLength: 4)
                Text("\(active.count) 个活跃端口")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            if snapshot.totalWatts != nil {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(USBCFormat.watts(snapshot.totalWatts, precision: 2))
                        .font(.system(size: 27, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("W")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text("SMC 输出端")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            if active.count > 1, let total = snapshot.totalWatts, total > 0 {
                GeometryReader { geometry in
                    HStack(spacing: 2) {
                        ForEach(active.indices, id: \.self) { index in
                            let port = active[index]
                            Capsule()
                                .fill(USBCFormat.tint(index))
                                .frame(width: max(0, geometry.size.width *
                                    CGFloat((port.watts ?? 0) / total) -
                                    CGFloat(active.count - 1) * 2 / CGFloat(active.count)))
                        }
                    }
                }
                .frame(height: 5)
            }

            if snapshot.ports.isEmpty {
                Text("暂未识别到 USB-C 接口")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if active.isEmpty {
                Text(snapshot.totalWatts == nil ? "尚无可用的 USB-C 输出功率读数" : "当前无 USB-C 对外供电")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            ForEach(Array(active.enumerated()), id: \.element.id) { index, port in
                USBCPortRow(port: port, tint: USBCFormat.tint(index),
                            devices: snapshot.devices.filter { $0.portID == port.id })
            }

            if !others.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        showsOtherPorts.toggle()
                    } label: {
                        HStack {
                            Text(showsOtherPorts ? "收起其他接口" : "其他接口（\(others.count)）")
                            Spacer()
                            Image(systemName: showsOtherPorts ? "chevron.up" : "chevron.down")
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.top, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    USBDisclosureDetails(expanded: showsOtherPorts) {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(others) { port in
                                USBCPortRow(port: port, tint: .secondary,
                                            devices: snapshot.devices.filter { $0.portID == port.id })
                            }
                        }
                        .padding(.top, 10)
                    }
                }
            }
        }
        .padding(12)
        .glassTile(radius: 26)
    }
}

private struct USBCPortRow: View {
    let port: USBCPortMeasurement
    let tint: Color
    let devices: [USBCDeviceLink]
    @State private var expanded = false

    private var currentSpeed: String {
        if let thunderbolt = port.currentGbps { return USBCFormat.speed(thunderbolt) }
        return USBCFormat.speed(devices.compactMap(\.linkGbps).max())
    }
    private var speedLabel: String {
        port.currentGbps != nil ? "当前雷雳链路" : "设备链路"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                expanded.toggle()
            } label: {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        Circle().fill(tint).frame(width: 6, height: 6)
                        Text(port.label)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 5)
                        Text(port.watts.map { "\(USBCFormat.watts($0, precision: 2)) W" } ?? "— W")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                    HStack(spacing: 5) {
                        Text(port.protocolName)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        Text("·")
                        Text(port.status)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("接口上限")
                            .foregroundStyle(.secondary)
                        Text(USBCFormat.speed(port.maximumGbps))
                        Spacer(minLength: 4)
                        Text(speedLabel)
                            .foregroundStyle(.secondary)
                        Text(currentSpeed)
                    }
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            USBDisclosureDetails(expanded: expanded) {
                VStack(alignment: .leading, spacing: 0) {
                    Rectangle().fill(Color.primary.opacity(0.10))
                        .frame(height: 1)
                        .padding(.vertical, 9)
                    HStack(spacing: 8) {
                        valueCard("输出电压", value: port.voltage, unit: "V")
                        valueCard("输出电流", value: port.current, unit: "A")
                    }
                    if !devices.isEmpty {
                        ForEach(devices.prefix(4)) { device in
                            HStack(spacing: 7) {
                                Image(systemName: "externaldrive")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                Text(device.name)
                                    .font(.system(size: 10))
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Text(USBCFormat.speed(device.linkGbps))
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .padding(.top, 7)
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.045),
                    in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private func valueCard(_ title: String, value: Double?, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value.map { String(format: "%.3f %@", $0, unit) } ?? "— \(unit)")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(Color.primary.opacity(0.045),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

/// IOKit-reported USB device link speeds. These devices are not attributed to
/// a physical connector without a verified registry-path association.
struct USBDeviceLinkSection: View {
    let devices: [USBCDeviceLink]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "cable.connector.horizontal")
                        .foregroundStyle(.secondary)
                    Text("已识别 USB 设备")
                        .font(.caption.weight(.semibold))
                    Spacer(minLength: 4)
                    Text("\(devices.count)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            USBDisclosureDetails(expanded: expanded) {
                VStack(alignment: .leading, spacing: 9) {
                    if devices.isEmpty {
                        Text("暂未识别到 USB 设备")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(devices.prefix(12)) { device in
                        HStack(spacing: 8) {
                            Image(systemName: "externaldrive")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(device.name)
                                    .font(.system(size: 11, weight: .semibold))
                                    .lineLimit(1)
                                if let portID = device.portID {
                                    Text(portID.replacingOccurrences(of: "Port-", with: "")
                                        .replacingOccurrences(of: "@", with: " "))
                                        .font(.system(size: 9))
                                        .foregroundStyle(.secondary)
                                }
                                if let allocated = device.allocatedWatts {
                                    Text("USB 分配功率 \(USBCFormat.watts(allocated, precision: 1)) W")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 4)
                            Text(USBCFormat.speed(device.linkGbps))
                                .font(.system(size: 11, weight: .semibold))
                                .monospacedDigit()
                        }
                        .padding(.vertical, 5)
                    }
                }
                .padding(.top, 9)
            }
        }
        .padding(12)
        .glassTile(radius: 26)
    }
}

private struct USBDisclosureDetails<Content: View>: View {
    let expanded: Bool
    @ViewBuilder let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        USBDisclosureLayout(progress: expanded ? 1 : 0) {
            content
        }
        .clipped()
        .allowsHitTesting(expanded)
        .accessibilityHidden(!expanded)
        .animation(reduceMotion ? nil : SidePanelNavigationMotion.animation(opening: expanded),
                   value: expanded)
    }
}

/// Reveal detail from its top edge and report the visible height to the side panel.
private struct USBDisclosureLayout: Layout {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews[0].sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: size.width, height: size.height * min(max(progress, 0), 1))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

enum USBCFormat {
    static func watts(_ watts: Double?, precision: Int) -> String {
        guard let watts, watts.isFinite, watts >= 0 else { return "—" }
        return String(format: "%.*f", precision, watts)
    }

    static func speed(_ gbps: Double?) -> String {
        guard let gbps, gbps.isFinite, gbps > 0 else { return "未提供" }
        return gbps < 1
            ? String(format: "%.0f Mb/s", gbps * 1000)
            : String(format: "%.0f Gb/s", gbps)
    }

    static func tint(_ index: Int) -> Color {
        let colors: [Color] = [
            Color(red: 0.22, green: 0.77, blue: 0.81),
            Color(red: 0.38, green: 0.61, blue: 1.0),
            Color(red: 0.65, green: 0.55, blue: 0.96)
        ]
        return colors[index % colors.count]
    }
}
