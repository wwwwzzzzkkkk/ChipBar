import SwiftUI

struct CPUCoreUsageSection: View {
    let samplingInterval: Int
    let active: Bool
    @StateObject private var model = CPUCoreLoadModel.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let topology = CPUCoreTopology.current

    private var verifiedCoreLabels: Bool {
        !model.values.isEmpty &&
        model.values.count == topology.namesByLogicalID.count
    }

    private func fullCoreName(_ id: Int) -> String {
        guard verifiedCoreLabels else { return "类型未确认" }
        return topology.namesByLogicalID[id] ?? "类型未确认"
    }

    private func tierColor(_ title: String) -> Color {
        switch title {
        case "超级核": return .orange
        case "性能核": return .cyan
        case "能效核": return Color(red: 0.31, green: 0.87, blue: 0.77)
        default: return .accentColor
        }
    }

    private func coreTint(_ id: Int) -> Color {
        guard verifiedCoreLabels else { return .accentColor }
        switch topology.namesByLogicalID[id] {
        case "超级核": return .orange
        case "性能核": return .cyan
        case "能效核": return Color(red: 0.31, green: 0.87, blue: 0.77)
        default: return .accentColor
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Text("CPU 各核心").font(.caption.weight(.semibold))
                Spacer(minLength: 3)
                if verifiedCoreLabels && !topology.levels.isEmpty {
                    ForEach(Array(topology.levels.enumerated()), id: \.offset) { _, tier in
                        HStack(spacing: 3) {
                            Circle()
                                .fill(tierColor(tier.shortTitle))
                                .frame(width: 6, height: 6)
                            Text("\(tier.shortTitle) \(tier.count)")
                                .lineLimit(1)
                                .minimumScaleFactor(0.78)
                        }
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                    }
                } else {
                    Text(model.hasSample ? "\(model.values.count) 核" : "正在采样")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            HStack(alignment: .bottom, spacing: 2) {
                if model.values.isEmpty {
                    Text("等待两次 CPU 计数器采样")
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).frame(height: 47)
                } else {
                    ForEach(Array(model.values.enumerated()), id: \.offset) { index, percent in
                        GeometryReader { geo in
                            ZStack(alignment: .bottom) {
                                Capsule().fill(.quaternary)
                                Capsule().fill(coreTint(index).opacity(0.78))
                                    .frame(height: geo.size.height * min(1, max(0, percent / 100)))
                                    .animation(reduceMotion || !active ? nil : .easeOut(duration: 0.23), value: percent)
                            }
                            .frame(maxWidth: 9)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .frame(maxWidth: .infinity)
                        .help("逻辑核心 \(index + 1) · \(fullCoreName(index))：\(Int(percent.rounded()))%")
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("逻辑核心 \(index + 1) · \(fullCoreName(index))")
                        .accessibilityValue("\(Int(percent.rounded()))%")
                    }
                }
            }.frame(height: 47)
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .glassTile(radius: 26)
        .task(id: "\(samplingInterval)-\(active)") {
            guard active else { return }
            await model.watch(intervalMillis: samplingInterval)
        }
    }
}
