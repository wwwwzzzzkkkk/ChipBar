import SwiftUI

/// Home combines internal/adapter power and USB-C output on one glass surface.
/// The two readings have different measurement boundaries and MUST NOT be
/// added together or drawn as a conservation/efficiency percentage.
struct PowerOverviewHomeTile: View {
    let reading: ChipBarPowerReading
    let selected: Bool
    let open: () -> Void

    private let inputTint = Color(red: 0.98, green: 0.73, blue: 0.30)
    private let outputTint = Color(red: 0.22, green: 0.76, blue: 0.80)

    private var inputTitle: String {
        if reading.hasBattery {
            return reading.onAdapter ? "适配器输入" : "电池供电"
        }
        // For Mac mini this is an SMC internal DC rail, not wall AC input.
        return "内部功率"
    }

    private var inputWatts: Double? {
        if reading.hasBattery && reading.onAdapter { return reading.adapterWatts }
        return reading.systemWatts
    }

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.horizontal.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(inputTint)
                    Text("电源与 USB-C")
                        .font(.caption.weight(.semibold))
                    Spacer(minLength: 4)
                    Image(systemName: selected ? "chevron.right" : "rectangle.on.rectangle")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                HStack(alignment: .center, spacing: 10) {
                    powerValue(inputTitle, watts: inputWatts,
                               icon: "bolt.fill", tint: inputTint)
                    Rectangle()
                        .fill(Color.primary.opacity(0.13))
                        .frame(width: 1, height: 40)
                        .accessibilityHidden(true)
                    powerValue("USB-C 输出", watts: reading.usb.totalWatts,
                               icon: "cable.connector", tint: outputTint)
                }

                HStack(spacing: 5) {
                    Text("每 3 秒刷新")
                    Spacer(minLength: 4)
                    Text("\(reading.usb.sourcingPorts.count) 个 USB-C 供电端口")
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassTile(radius: 26, tint: selected ? outputTint.opacity(0.12) : nil,
                       interactive: true)
            .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
        .buttonStyle(ChipBarPressStyle())
        .accessibilityLabel(
            "\(inputTitle) \(USBCFormat.watts(inputWatts, precision: 1)) 瓦，" +
            "USB-C 对外供电 \(USBCFormat.watts(reading.usb.totalWatts, precision: 2)) 瓦"
        )
        .accessibilityHint("显示电源与 USB-C 端口详情")
    }

    private func powerValue(_ title: String, watts: Double?,
                            icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                    .font(.system(size: 10))
                Text(title)
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(USBCFormat.watts(watts, precision: 1))
                    .font(.system(size: 23, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text("W")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
