import SwiftUI
import ChipBarCore

enum ApplicationResource: String, CaseIterable, Identifiable {
    case cpu = "CPU", gpu = "GPU", memory = "内存", ane = "ANE"
    var id: String { rawValue }
}

struct ApplicationUsageSection: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var state: DashboardState
    var showsDisclosure = true
    @StateObject private var activity = ApplicationActivityModel.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var samplingStartedInThisPanel = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsDisclosure {
                if #available(macOS 14.0, *) {
                    disclosureButton.focusEffectDisabled()
                } else {
                    disclosureButton
                }
            }
            ApplicationMetricSelector(selection: $state.applicationMetric)
            // Changing metrics creates a separate view identity: the old
            // metric keeps its own numbers as it recedes behind the new page.
            // Incoming rankings float DOWN from above, not up from below.
            // The viewport never changes height while switching resources.
            ZStack(alignment: .topLeading) {
                ranking(for: state.applicationMetric)
                    .id(state.applicationMetric)
                    .transition(reduceMotion ? .opacity :
                        .asymmetric(
                            insertion: .opacity
                                .combined(with: .offset(y: -14))
                                .combined(with: .scale(scale: 1.015, anchor: .top)),
                            removal: .opacity
                                .combined(with: .scale(scale: 0.94, anchor: .center))))
            }
            .frame(height: 84 + 56 * state.applicationsExpansion, alignment: .topLeading)
            .clipped()
            .animation(ChipBarMotion.optional(ChipBarMotion.resourceStack,
                                              reduceMotion: reduceMotion), value: state.applicationMetric)
            // Keep the ranking scannable. Advanced measurement caveats
            // remain available on hover and to assistive technologies.
            .help(explanation)
            .accessibilityHint(explanation)
        }
        .task(id: "\(monitor.paused)-\(monitor.sleeping)-\(monitor.interval)-\(state.applicationMetric == .gpu)") {
            guard !monitor.paused, !monitor.sleeping else { return }
            if !samplingStartedInThisPanel {
                // Avoid hundreds of libproc reads competing with the first
                // Liquid Glass layout. Subsequent metric changes are immediate.
                do { try await Task.sleep(for: .milliseconds(350)) }
                catch { return }
                guard !Task.isCancelled else { return }
                samplingStartedInThisPanel = true
            }
            await activity.watch(interval: monitor.interval,
                                 includeGPU: state.applicationMetric == .gpu)
        }
    }

    private var disclosureButton: some View {
        Button {
            withAnimation(reduceMotion ? nil : ChipBarMotion.disclosure) {
                state.toggleApplications()
            }
        } label: {
            HStack {
                Text("应用占用").font(.subheadline.weight(.medium))
                Spacer()
                Text(state.showApplications ? "收起" : "更多").font(.caption)
                Image(systemName: "chevron.down").font(.caption2)
                    .rotationEffect(.degrees(180 * state.applicationsExpansion))
            }.contentShape(Rectangle())
        }.buttonStyle(ChipBarPressStyle())
            .accessibilityLabel(state.showApplications ? "收起为前三名应用" : "查看前五名应用及指标说明")
    }

    @ViewBuilder private func ranking(for metric: ApplicationResource) -> some View {
        if monitor.paused || monitor.sleeping {
            message("应用占用采样已暂停", symbol: "pause.circle")
        } else if let snapshot = activity.snapshot {
            let rows = rankedRows(snapshot, metric: metric)
            if !rows.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        HStack(spacing: 7) {
                                Text("\(index + 1)").monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .frame(width: 15)
                                    .accessibilityHidden(true)
                                if let path = row.appPath {
                                    Image(nsImage: ApplicationIconCache.icon(for: path))
                                        .resizable()
                                        .interpolation(.high)
                                        .frame(width: 15, height: 15)
                                        .accessibilityHidden(true)
                                } else {
                                    Image(systemName: "app")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 15, height: 15)
                                        .accessibilityHidden(true)
                                }
                                Text(row.name).lineLimit(1).truncationMode(.middle)
                                    .help("\(row.name) · 合并 \(row.processCount) 个进程；只统计可读取的计数器")
                                Spacer(minLength: 5)
                                Text(formatted(row, metric: metric))
                                    .monospacedDigit()
                                    .foregroundStyle(.primary)
                            }
                        .font(.caption)
                        .frame(height: 28)
                        .opacity(index < 3 ? 1 : state.applicationsExpansion)
                        .accessibilityElement(children: .combine)
                        .accessibilityHidden(!state.showApplications && index >= 3)
                    }
                }
            } else {
                message(emptyMessage(snapshot, metric: metric), symbol: "chart.bar.xaxis")
            }
        } else {
            message("正在读取应用占用…", symbol: "clock")
        }
    }

    private func rankedRows(_ snapshot: ActivitySnapshot, metric: ApplicationResource) -> [ApplicationActivityRow] {
        Array(snapshot.rows.filter {
            (value($0, metric: metric) ?? -1) > (metric == .ane || metric == .memory ? 0 : -1)
        }
            .sorted {
                let lhs = value($0, metric: metric) ?? 0, rhs = value($1, metric: metric) ?? 0
                return lhs == rhs ? $0.id < $1.id : lhs > rhs
            }.prefix(5))
    }

    private func value(_ row: ApplicationActivityRow, metric: ApplicationResource) -> Double? {
        switch metric {
        case .cpu: return row.cpuPercent
        case .gpu: return row.gpuPercent
        case .memory: return ApplicationMemoryDisplay.validatedBytes(row.physicalBytes).map(Double.init)
        case .ane: return row.neuralBytes.map(Double.init)
        }
    }

    private func formatted(_ row: ApplicationActivityRow, metric: ApplicationResource) -> String {
        guard let number = value(row, metric: metric) else { return "—" }
        switch metric {
        case .cpu, .gpu: return String(format: "%.1f%%", number)
        case .memory:
            return ApplicationMemoryDisplay.text(bytes: row.physicalBytes,
                                                  approximate: row.memoryIsRSSApproximation)
        case .ane:
            if number >= 1_000_000_000 { return String(format: "%.2f GB", number / 1_000_000_000) }
            if number >= 1_000_000 { return String(format: "%.1f MB", number / 1_000_000) }
            return String(format: "%.1f KB", number / 1_000)
        }
    }

    private func emptyMessage(_ snapshot: ActivitySnapshot, metric: ApplicationResource) -> String {
        switch metric {
        case .cpu: return snapshot.readableCPUCount > 0 ? "正在建立 CPU 采样基线…" : "当前无法读取进程 CPU 计数器"
        case .gpu: return snapshot.gpuClientCount > 0 ? "正在建立 GPU 采样基线…" : "当前驱动未提供应用 GPU 时间"
        case .memory: return snapshot.readableMemoryCount > 0 ? "当前未观察到非零应用内存读数" : "当前无法读取应用内存"
        case .ane: return snapshot.neuralSupported ? "当前未观察到已记账的 ANE 内存" : "当前环境未提供应用 ANE 内存"
        }
    }

    private var explanation: String {
        switch state.applicationMetric {
        case .cpu: return "100% 表示占满一个逻辑核心，多核应用可超过100%。同一应用内的辅助进程合并统计。"
        case .gpu: return "驱动 GPU 时间 / 采样间隔，可超过100%；不等同于整机 GPU 利用率的分摊。共享服务单独显示。"
        case .memory: return "优先统计进程物理足迹（Physical Footprint）；系统无法提供时使用 RSS 驻留内存近似值（≈），并合并可读取的应用辅助进程。RSS 与活动监视器的内存不完全一致。"
        case .ane: return "此处为 ANE 记账内存，不是计算利用率。系统未提供逐应用 ANE 计算百分比；没有记账不代表未使用 ANE。"
        }
    }

    private func message(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .multilineTextAlignment(.center)
    }
}
