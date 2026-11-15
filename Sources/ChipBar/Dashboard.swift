import SwiftUI
import QuartzCore
import ChipBarCore

enum DashboardLayout {
    static let width: CGFloat = 378
}

enum DashboardMotion {
    static let duration = 0.20
    static let navigation = 0.24
    // The page slide finishes before the glass window settles to its new size.
    static let navigationResize = 0.34
    static let navigationSpringCurve = CAMediaTimingFunction(controlPoints: 0.22, 0.72, 0.30, 1.00)
    static let popoverEnter = 0.18
    static let popoverExit = 0.14
    static let popoverCurve = CAMediaTimingFunction(name: .easeInEaseOut)
}

final class DashboardState: ObservableObject {
    @Published var sidePanel: DashboardSidePanelKind? = nil
    @Published var selectedExternalVolumeID: String? = nil
    @Published var chartMetric: PowerMetric = .total
    @Published var showSettings = false
    @Published var showApplications = CommandLine.arguments.contains("--apps")
    @Published var applicationsExpansion = CommandLine.arguments.contains("--apps") ? 1.0 : 0.0
    @Published var showSSDDetails = CommandLine.arguments.contains("--ssd-details")
    @Published var showSystemDetails = CommandLine.arguments.contains("--system-details")
        || CommandLine.arguments.contains("--ssd-details")
        || CommandLine.arguments.contains("--ssd-disclosure-only")
    @Published var ssdExpansion = CommandLine.arguments.contains("--ssd-details") ? 1.0 : 0.0
    @Published var ssdDetailsHeight: CGFloat = 0
    @Published var applicationMetric: ApplicationResource = CommandLine.arguments.contains("--apps-gpu") ? .gpu : CommandLine.arguments.contains("--apps-ane") ? .ane : .cpu
    init(showSettings: Bool = false) {
        self.showSettings = showSettings
    }
    /// Every menu-bar open starts from the same visual state. Saved user
    /// preferences (refresh interval, menu items and SSD monitoring) remain.
    /// Dedicated -- QA flags are preserved for screenshot/interaction tests.
    func resetForOpening(arguments: [String] = CommandLine.arguments) {
        let apps = arguments.contains("--apps")
        let ssd = arguments.contains("--ssd-details")
        let system = arguments.contains("--system-details") || ssd
            || arguments.contains("--ssd-disclosure-only")
        chartMetric = .total
        sidePanel = nil
        selectedExternalVolumeID = nil
        showSettings = false
        showApplications = apps
        applicationsExpansion = apps ? 1 : 0
        showSSDDetails = ssd
        ssdExpansion = ssd ? 1 : 0
        showSystemDetails = system
        ssdDetailsHeight = 0
        applicationMetric = arguments.contains("--apps-gpu") ? .gpu :
            arguments.contains("--apps-ane") ? .ane : .cpu
    }
    func toggleApplications() {
        showApplications.toggle()
        applicationsExpansion = showApplications ? 1 : 0
    }
    func toggleSettings() { showSettings.toggle() }
}

struct Dashboard: View {
    @ObservedObject var monitor: Monitor
    @StateObject private var state: DashboardState
    @StateObject private var updater = ChipBarUpdater.shared
    @ObservedObject private var tileLayout = DashboardTileLayoutModel.shared
    @StateObject private var powerReading = ChipBarPowerFlowModel.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let accent = Color(red: 0.22, green: 0.65, blue: 0.79)
    private let appIcon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
        .flatMap { NSImage(contentsOf: $0) }

    init(monitor: Monitor, showSettings: Bool = false, state: DashboardState? = nil) {
        self.monitor = monitor
        _state = StateObject(wrappedValue: state ?? DashboardState(showSettings: showSettings))
    }

    private var showsDeviceAndSettings: Bool {
        state.showSettings || state.showSystemDetails
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if showsDeviceAndSettings {
                settingsScreen
                    .transition(reduceMotion ? .opacity :
                        .asymmetric(
                            insertion: .offset(x: 18).combined(with: .opacity),
                            removal: .offset(x: 18).combined(with: .opacity)))
            } else {
                monitoringScreen
                    .transition(reduceMotion ? .opacity :
                        .asymmetric(
                            insertion: .offset(x: -18).combined(with: .opacity),
                            removal: .offset(x: -18).combined(with: .opacity)))
            }
        }
        // Constrain the *content* rather than only its padded outer frame.
        // Otherwise intrinsic widths (e.g. segmented picker) can run under
        // the scroller and clip the right-hand side of the glass popover.
        .frame(width: DashboardLayout.width - 30, alignment: .topLeading)
        .padding(.horizontal, 15)
        .padding(.vertical, 14)
        .frame(width: DashboardLayout.width, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .buttonStyle(ChipBarPressStyle())
        // One navigation state and one animation transaction: having a second
        // animation for the old System page could briefly restyle the material
        // during Settings transitions.
        .animation(ChipBarMotion.optional(ChipBarMotion.navigation, reduceMotion: reduceMotion),
                   value: showsDeviceAndSettings)
        .transaction { transaction in
            if !monitor.dashboardVisible || monitor.paused || monitor.sleeping {
                transaction.disablesAnimations = true
            }
        }
    }

    private var monitoringScreen: some View {
        DashboardGlassContainer {
            monitoringTiles
        }
    }

    /// Reorderable six-track mosaic. Stable tile identities preserve
    /// animated gauges and background sampling when tiles move.
    private var monitoringTiles: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                header
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    if tileLayout.editing {
                        tileLayout.finishEditing(reduceMotion: reduceMotion)
                    } else {
                        withAnimation(reduceMotion ? nil :
                                      .spring(response: 0.32, dampingFraction: 0.76)) {
                            tileLayout.editing = true
                        }
                    }
                } label: {
                    Label(tileLayout.editing ? "完成" : "排列",
                          systemImage: tileLayout.editing ? "checkmark.circle.fill" : "square.grid.2x2")
                        .font(.caption2.weight(.medium))
                }
                .frame(width: 65, alignment: .trailing)
                .buttonStyle(ChipBarPressStyle())
                .accessibilityLabel(tileLayout.editing ? "完成磁贴排列" : "自定义磁贴排列")
            }

            ChipBarAdaptiveTileLayout {
                ForEach(tileLayout.visible) { tile in
                    homeTile(tile)
                        // Keep the hit target active during the same mouse
                        // press that turns edit mode on. Disabling the entire
                        // subtree can cancel an in-flight DragGesture.
                        .overlay(alignment: .topTrailing) {
                            if tileLayout.editing {
                                Image(systemName: "line.3.horizontal")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.primary)
                                    .padding(5)
                                    .background(.regularMaterial, in: Capsule())
                                    .padding(5)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            }
                        }
                        // The selected tile lifts off the glass; an active drag
                        // leaves a translucent home-position guide. On release,
                        // a brief compression joins the spring landing.
                        .overlay {
                            if tileLayout.highlighted == tile || tileLayout.settling == tile {
                                RoundedRectangle(cornerRadius: 25, style: .continuous)
                                    .strokeBorder(Color.accentColor.opacity(0.75), lineWidth: 1.8)
                                    .padding(2)
                                    .allowsHitTesting(false)
                            }
                        }
                        .scaleEffect(tileLayout.settling == tile ? 0.94 :
                                     tileLayout.highlighted == tile && tileLayout.dragging == nil
                                     ? 1.035 : 1)
                        .offset(y: tileLayout.highlighted == tile &&
                                   tileLayout.dragging == nil ? -3 : 0)
                        .shadow(color: .black.opacity(tileLayout.highlighted == tile &&
                                                      tileLayout.dragging == nil ? 0.22 : 0),
                                radius: 13, y: 6)
                        .opacity(tileLayout.dragging == tile ? 0.24 : 1)
                        .zIndex(tileLayout.highlighted == tile ? 5 : 0)
                        .contentShape(Rectangle())
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: ChipBarTileFramePreference.self,
                                    value: [tile: proxy.frame(in: .named("chipbar.tileMosaic"))])
                            }
                        }
                        // One uninterrupted gesture controls press, pickup,
                        // pointer tracking and release. The pointer itself is
                        // never animated and never starts an NSItemProvider
                        // drag session inside the glass NSPanel.
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 0,
                                        coordinateSpace: .named("chipbar.tileMosaic"))
                                .onChanged { value in
                                    tileLayout.trackPress(tile, point: value.location,
                                                          reduceMotion: reduceMotion)
                                }
                                .onEnded { _ in
                                    tileLayout.endPress(tile, reduceMotion: reduceMotion)
                                }
                        )
                        .accessibilityHint("长按约半秒进入排列模式，然后按住直接移动；松手弹性落位")
                        .chipBarTileSpan(tile.columns)
                }
            }
            .coordinateSpace(name: "chipbar.tileMosaic")
            .overlay(alignment: .topLeading) {
                ChipBarFloatingDragTile(motion: tileLayout.pointer)
            }
            .onPreferenceChange(ChipBarTileFramePreference.self) { frames in
                tileLayout.tileFrames = frames
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(reduceMotion ? nil : .spring(response: 0.33, dampingFraction: 0.90),
                       value: tileLayout.arrangement)

            errorPanel
            Text(monitor.status).font(.caption).foregroundStyle(.secondary)
            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Exactly one sampler task for the dashboard. The old power tile used
        // to own it, which left a USB-C-only layout without live readings.
        .task(id: monitor.dashboardVisible && !monitor.paused && !monitor.sleeping) {
            guard monitor.dashboardVisible, !monitor.paused,
                  !monitor.sleeping else { return }
            await powerReading.watch(chipPower: {
                monitor.connected ? monitor.sample?.total : nil
            }, needsUSBDevices: {
                state.sidePanel == .power
            })
        }
    }

    @ViewBuilder private func homeTile(_ tile: DashboardTile) -> some View {
        switch tile {
        case .powerTrend:
            hero
        case .cpu:
            DashboardRunway(
                title: "CPU", percentage: monitor.connected ? monitor.sample?.cpuUtilization : nil,
                color: Color(red: 0.36, green: 0.62, blue: 1.0),
                subtitle: wattage(monitor.connected ? monitor.sample?.cpu : nil),
                detail: temperatureSummary(monitor.connected ? monitor.sample?.cpuTemperature : nil),
                active: monitor.dashboardVisible && !monitor.paused && !monitor.sleeping)
        case .gpu:
            DashboardRunway(
                title: "GPU", percentage: monitor.connected ? monitor.sample?.gpuUtilization : nil,
                color: Color(red: 0.69, green: 0.56, blue: 0.99),
                subtitle: wattage(monitor.connected ? monitor.sample?.gpu : nil),
                detail: temperatureSummary(monitor.connected ? monitor.sample?.gpuTemperature : nil),
                active: monitor.dashboardVisible && !monitor.paused && !monitor.sleeping)
        case .memory:
            DashboardRunway(
                title: "内存", percentage: monitor.connected ? monitor.sample?.memory?.usedPercent : nil,
                color: MemoryPressureRingStyle.tint(for: monitor.memoryPressure),
                subtitle: memoryUsedSummary, detail: memoryTotalSummary,
                pressureStatus: monitor.memoryPressure.title,
                active: monitor.dashboardVisible && !monitor.paused && !monitor.sleeping)
        case .cpuCores:
            CPUCoreUsageSection(samplingInterval: monitor.interval,
                                active: monitor.dashboardVisible && !monitor.paused && !monitor.sleeping)
        case .fan:
            homeFanTile
        case .ane:
            DashboardANEStrip(power: monitor.sample?.ane, connected: monitor.connected)
        case .storage:
            StorageCapacitySection(state: state)
        case .powerSupply:
            PowerOverviewHomeTile(reading: powerReading.reading,
                                  selected: state.sidePanel == .power) {
                guard !tileLayout.editing else { return }
                state.sidePanel = state.sidePanel == .power ? nil : .power
            }
        case .applications:
            sidePanelEntry("应用占用", icon: "square.stack.3d.up", kind: .applications)
        case .cluster:
            ClusterOverviewTile(selected: state.sidePanel == .cluster) {
                guard !tileLayout.editing else { return }
                state.sidePanel = state.sidePanel == .cluster ? nil : .cluster
            }
        }
    }

    /// The only secondary page: system facts, hardware details and settings.
    /// Home remains compact, with internal/external storage space bars.
    private var settingsScreen: some View {
        VStack(alignment: .leading, spacing: 8) {
            settingsNavigation
            MacHardwareInformationSection(chip: monitor.sample?.chip ?? monitor.hardware)
            settingsPanel
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var settingsNavigation: some View {
        HStack(spacing: 10) {
            Button {
                if state.showSettings { state.showSettings = false }
                else { state.showSystemDetails = false }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 30, height: 30)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
                    .contentShape(RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(ChipBarPressStyle())
            .accessibilityLabel("返回监控面板")
            Text("设备与设置")
                .font(.headline)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var header: some View {
            HStack(spacing: 10) {
                if let appIcon {
                    Image(nsImage: appIcon).resizable().interpolation(.high)
                        .frame(width: 28, height: 28).accessibilityHidden(true)
                } else {
                    Image(systemName: "waveform.path.ecg")
                        .font(.title2).foregroundStyle(accent)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("ChipBar").font(.headline)
                    Text(monitor.sample?.chip ?? monitor.hardware)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer()
                Circle().fill(monitor.connected ? Color.green : Color.orange).frame(width: 6, height: 6)
                Text(monitor.paused ? "已暂停" : monitor.connected ? "实时" : "等待数据")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }

    }

    /// Keep RAM capacity outside the shared ring box while leaving the
    /// memory usage percentage and macOS pressure-colored stroke unchanged.
    private var memoryUsedSummary: String {
        guard monitor.connected, let memory = monitor.sample?.memory else { return "— GB" }
        return String(format: "%.1f GB", memory.usedGiB)
    }

    private var memoryTotalSummary: String {
        guard monitor.connected, let memory = monitor.sample?.memory else { return "共 — GB" }
        return String(format: "共 %.1f GB", memory.totalGiB)
    }

    /// One and only one power history chart: the headline and real rolling
    /// 10-minute graph form the dashboard's single information focal point.
    // The headline and y-axis now share the same top boundary. Both columns
    // reserve exactly 70 pt, so loading/empty states do not shift the header.
    private var totalPowerHeadline: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("芯片总功率")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(height: 14, alignment: .topLeading)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                AnimatedMetricValue(value: monitor.connected ? monitor.sample?.total : nil)
                    .font(.system(size: 27, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text("W")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(height: 34, alignment: .leading)
            Text("CPU + GPU + ANE")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(height: 12, alignment: .leading)
        }
        .frame(width: 82, height: 70, alignment: .topLeading)
    }

    @ViewBuilder private var totalPowerChart: some View {
        if monitor.powerChart.points.isEmpty {
            Text("等待功率采样")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 70)
        } else {
            PowerTrendPlot(
                points: monitor.powerChart.points,
                maximum: monitor.powerChart.maximum,
                timeline: monitor.powerChart.timeline,
                accent: accent
            )
            .frame(height: 70)
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 4) {
                totalPowerHeadline
                totalPowerChart
            }
            .frame(height: 70, alignment: .top)
            HStack(spacing: 8) {
                Text("最近 10 分钟")
                Spacer()
                Text("均值 \(value(monitor.powerChart.average)) W")
            }
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .glassTile(radius: 26)
    }

    @ViewBuilder private var powerCards: some View {
        HStack(alignment: .top, spacing: 8) {
            DashboardRunway(
                title: "CPU", percentage: monitor.connected ? monitor.sample?.cpuUtilization : nil,
                color: Color(red: 0.36, green: 0.62, blue: 1.0),
                subtitle: wattage(monitor.connected ? monitor.sample?.cpu : nil),
                detail: temperatureSummary(monitor.connected ? monitor.sample?.cpuTemperature : nil),
                active: monitor.dashboardVisible && !monitor.paused && !monitor.sleeping)
            DashboardRunway(
                title: "GPU", percentage: monitor.connected ? monitor.sample?.gpuUtilization : nil,
                color: Color(red: 0.69, green: 0.56, blue: 0.99),
                subtitle: wattage(monitor.connected ? monitor.sample?.gpu : nil),
                detail: temperatureSummary(monitor.connected ? monitor.sample?.gpuTemperature : nil),
                active: monitor.dashboardVisible && !monitor.paused && !monitor.sleeping)
            DashboardRunway(
                title: "内存", percentage: monitor.connected ? monitor.sample?.memory?.usedPercent : nil,
                color: MemoryPressureRingStyle.tint(for: monitor.memoryPressure),
                subtitle: memoryUsedSummary,
                detail: memoryTotalSummary,
                pressureStatus: monitor.memoryPressure.title,
                active: monitor.dashboardVisible && !monitor.paused && !monitor.sleeping)
        }
    }

    private func sidePanelEntry(_ title: String, icon: String,
                                kind: DashboardSidePanelKind,
                                trailingValue: Double? = nil) -> some View {
        let selected = state.sidePanel == kind
        return Button {
            guard !tileLayout.editing else { return }
            if kind == .applications && state.sidePanel != .applications {
                // The sidecar may show five rows without growing the main window.
                state.showApplications = true
                state.applicationsExpansion = 1
            }
            state.sidePanel = selected ? nil : kind
        } label: {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(accent)
                Text(title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 2)
                if kind == .power {
                    Text(wattage(trailingValue))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .foregroundStyle(.primary)
                }
                Image(systemName: selected ? "chevron.right" : "rectangle.on.rectangle")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 11)
            .frame(height: 41)
            .glassTile(radius: 21, tint: selected ? accent.opacity(0.13) : nil,
                       interactive: true)
            .contentShape(RoundedRectangle(cornerRadius: 21, style: .continuous))
        }
        .buttonStyle(ChipBarPressStyle())
        .accessibilityLabel("\(title)，\(kind == .power ? wattage(trailingValue) : "")，\(selected ? "收起" : "在侧边卡片展开")")
    }

    private func wattage(_ power: Double?) -> String {
        guard let power, power.isFinite else { return "— W" }
        return String(format: "%.1f W", power)
    }

    private func temperatureSummary(_ temperature: Double?) -> String {
        guard let temperature, temperature.isFinite else { return "温度不可用" }
        return String(format: "%.1f°C", temperature)
    }

    @ViewBuilder private var errorPanel: some View {
            if let error = monitor.error {
                VStack(alignment: .leading, spacing: 5) {
                    Label("采样需要处理", systemImage: "exclamationmark.triangle").font(.caption.weight(.semibold))
                    Text(error).font(.caption).textSelection(.enabled).lineLimit(5)
                    Button("立即重试") { monitor.restart() }.font(.caption)
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            }

    }

    private var homeFanTile: some View {
        let fans = monitor.connected ? monitor.sample?.fans ?? [] : []
        return HStack(spacing: 7) {
            Image(systemName: "fanblades")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(accent)
            Text("风扇")
                .font(.caption.weight(.medium))
            Spacer(minLength: 2)
            Text(fans.isEmpty ? "— RPM" :
                 fans.map { String(format: "%.0f", $0.rpm) }.joined(separator: "/") + " RPM")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 11)
        .frame(maxWidth: .infinity)
        .frame(height: 43)
        .glassTile(radius: 26)
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("采样频率", systemImage: "clock.arrow.circlepath")
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 0)
                }
                RefreshIntervalSelector(selection: $monitor.interval)
            }
            .padding(11)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 13))

            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Label("菜单栏显示", systemImage: "menubar.rectangle")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(monitor.menuItems.count + (monitor.ssd.menuTemperaturesEnabled ? 1 : 0)) / 9 已显示")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                    GridRow {
                        menuChoice(.logo)
                        menuChoice(.power)
                        menuChoice(.utilization)
                    }
                    GridRow {
                        menuChoice(.memory)
                        menuChoice(.cpuTemperature)
                        menuChoice(.fans)
                    }
                    GridRow {
                        menuChoice(.network)
                        menuChoice(.disk)
                        menuSSDTemperatureChoice
                    }
                }
                if monitor.menuItems.contains(.power) {
                    LiquidGlassSegmentedSelector(
                        selection: $monitor.menuMetric,
                        options: PowerMetric.allCases.map {
                            LiquidGlassSegment(value: $0, title: $0.title)
                        },
                        accessibilityLabel: "菜单栏功率指标"
                    )
                }
            }
            .padding(11)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 13))

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Label("应用更新", systemImage: "arrow.triangle.2.circlepath")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                         as? String ?? "开发版本")
                        .font(.caption2).foregroundStyle(.secondary)
                    if updater.busy { ProgressView().controlSize(.small) }
                    Button("检查更新") { updater.check() }
                        .font(.caption)
                        .disabled(updater.busy)
                }
                if updater.busy || updater.availableVersion != nil ||
                    updater.status != "检查是否有可用的新版本。" {
                    Text(updater.status)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let version = updater.availableVersion {
                    Button {
                        updater.install()
                    } label: {
                        Label("下载并安装 ChipBar \(version)", systemImage: "arrow.down.app")
                    }
                    .font(.caption.weight(.medium))
                    .disabled(updater.busy)
                }
            }
            .padding(11)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 13))

            if !monitor.connected {
                Text("macmon 未连接，请检查安装后重试。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func menuChoice(_ item: MenuContent) -> some View {
        let enabled = monitor.menuItems.contains(item)
        return Button {
            withAnimation(ChipBarMotion.optional(ChipBarMotion.selection,
                                                 reduceMotion: reduceMotion)) {
                if enabled { monitor.menuItems.remove(item) }
                else { monitor.menuItems.insert(item) }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: menuIcon(item))
                    .font(.system(size: 11))
                    .frame(width: 13)
                Text(menuTitle(item))
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                if enabled {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .semibold))
                }
            }
            .foregroundStyle(enabled ? Color.black : .primary)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .frame(maxWidth: .infinity)
            .modifier(MenuChoiceSurface(selected: enabled))
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(ChipBarPressStyle())
        .accessibilityLabel(item.title)
        .accessibilityValue(enabled ? "已显示" : "未显示")
    }

    /// SSD temperatures have a separate persisted master preference from
    /// MenuContent. Render it with exactly the same pill as all other menu
    /// items, without changing per-drive SMART selections.
    private var menuSSDTemperatureChoice: some View {
        let enabled = monitor.ssd.menuTemperaturesEnabled
        return Button {
            withAnimation(ChipBarMotion.optional(ChipBarMotion.selection,
                                                 reduceMotion: reduceMotion)) {
                monitor.ssd.setMenuTemperatureVisibility(!enabled)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "thermometer.medium")
                    .font(.system(size: 11))
                    .frame(width: 13)
                Text("SSD 温度")
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                if enabled {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .semibold))
                }
            }
            .foregroundStyle(enabled ? Color.black : .primary)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .frame(maxWidth: .infinity)
            .modifier(MenuChoiceSurface(selected: enabled))
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(ChipBarPressStyle())
        .accessibilityLabel("菜单栏 SSD 温度")
        .accessibilityValue(enabled ? "已显示" : "未显示")
        .accessibilityHint("即使当前没有外置硬盘也能修改此偏好")
    }

    private func menuTitle(_ item: MenuContent) -> String {
        switch item {
        case .logo: return "Logo"
        case .power: return "功率"
        case .utilization: return "CPU / GPU"
        case .memory: return "内存"
        case .cpuTemperature: return "CPU 温度"
        case .fans: return "风扇"
        case .network: return "网络速率"
        case .disk: return "磁盘速率"
        case .externalDisk: return "外置磁盘"
        }
    }

    private func menuIcon(_ item: MenuContent) -> String {
        switch item {
        case .logo: return "bolt.fill"
        case .power: return "bolt"
        case .utilization: return "cpu"
        case .memory: return "memorychip"
        case .cpuTemperature: return "thermometer"
        case .fans: return "fanblades"
        case .network: return "arrow.up.arrow.down"
        case .disk: return "internaldrive"
        case .externalDisk: return "externaldrive"
        }
    }

    @ViewBuilder private var footer: some View {
            VStack {
            Divider()
            HStack {
                Button { state.showSettings = true } label: {
                    HStack(spacing: 6) {
                        Label("设备与设置", systemImage: "slider.horizontal.3")
                        Image(systemName: "chevron.right").font(.caption2)
                    }
                }
                .accessibilityLabel("打开设备信息与设置页面")
                Spacer()
                Button(monitor.paused ? "继续" : "暂停") { monitor.togglePause() }
                Button("退出") { monitor.stop(forQuit: true); NSApplication.shared.terminate(nil) }
            }.buttonStyle(ChipBarPressStyle()).font(.subheadline)
            }
    }

    /// Pin the x-axis to a real 10-minute window ending at the latest
    /// received sample. On startup, a few data points occupy only the most
    /// recent part of the plot instead of stretching to its entire width.
    private func value(_ number: Double?) -> String { number.map { String(format: "%.1f", $0) } ?? "—" }
    private func temperature(_ number: Double?) -> String {
        guard monitor.connected, let number else { return "不可用" }
        return String(format: "%.1f °C", number)
    }
}

