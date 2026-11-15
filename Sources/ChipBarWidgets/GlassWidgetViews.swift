import AppKit
import SwiftUI
import WidgetKit

// MARK: - Semantic palette

enum GlassPalette {
    static let cpu = Color(red: 90/255, green: 169/255, blue: 1)
    static let gpu = Color(red: 177/255, green: 140/255, blue: 1)
    static let memory = Color(red: 94/255, green: 234/255, blue: 212/255)
    static let power = Color(red: 251/255, green: 191/255, blue: 36/255)
    static let ane = Color(red: 249/255, green: 168/255, blue: 212/255)
    static let fan = Color(red: 125/255, green: 211/255, blue: 252/255)
    static let online = Color(red: 74/255, green: 222/255, blue: 128/255)
    static let warning = Color(red: 1, green: 216/255, blue: 77/255)

    static func memoryColor(_ percent: Double) -> Color {
        percent >= 80 ? warning : memory
    }
}

enum GlassFormat {
    static func decimal(_ value: Double?, precision: Int = 1) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        return String(format: precision == 0 ? "%.0f" : "%.1f", value)
    }

    static func capacity(_ bytes: Int64) -> (number: String, unit: String) {
        if bytes >= 1_000_000_000_000 {
            return (String(format: "%.2f", Double(bytes) / 1_000_000_000_000), "TB")
        }
        return (String(format: "%.2f", Double(bytes) / 1_000_000_000), "GB")
    }

    static func power(_ watts: Double?) -> String {
        decimal(watts) + " W"
    }
}

/// The numeric value and unit are one Text, sharing a baseline. A common
/// minimum scale prevents clipping at the system's smallest widget dimensions.
struct GlassNumberText: View {
    let text: String
    let unit: String
    let size: CGFloat
    let tint: Color

    var body: some View {
        (
            Text(text)
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .foregroundColor(tint)
            +
            Text(" " + unit)
                .font(.system(size: size * 0.5, weight: .medium, design: .rounded))
                .foregroundColor(.secondary)
        )
        .tracking(-size * 0.02)
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.64)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Shared drawing primitives (static paths only, no animation)

struct RingView: View {
    let percent: Double?
    let color: Color
    let lineWidth: CGFloat
    let label: String
    let diameter: CGFloat
    let watts: Double?
    let tempC: Double?
    var fontSize: CGFloat = 11.5

    private var progress: CGFloat {
        CGFloat(min(100, max(0, percent ?? 0))) / 100
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.11), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    LinearGradient(
                        colors: [color, color.opacity(0.65), .white.opacity(0.68)],
                        startPoint: .bottomLeading, endPoint: .topTrailing),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: color.opacity(0.67), radius: 3)
                .widgetAccentable()
            Text(GlassFormat.decimal(percent, precision: 0) + "%")
                .font(.system(size: fontSize, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            String(format: String(localized: "%@ 占用 %@%%，功率 %@ 瓦，温度 %@ 度"),
                   label, GlassFormat.decimal(percent, precision: 0),
                   GlassFormat.decimal(watts), GlassFormat.decimal(tempC))
        )
    }
}

struct SparklineView: View {
    let values: [Double]
    let color: Color
    let showGrid: Bool
    let average: Double?
    let current: Double?

    private func coordinates(_ size: CGSize) -> [CGPoint] {
        guard !values.isEmpty else { return [] }
        let ceiling = max(0.5, (values.max() ?? 0) * 1.1)
        let w = max(0, size.width - 12)
        let h = max(1, size.height - 12)
        return values.enumerated().map { index, value in
            CGPoint(x: 6 + w * CGFloat(index) / CGFloat(max(1, values.count - 1)),
                    y: 6 + h * (1 - CGFloat(max(0, value) / ceiling)))
        }
    }

    private func curve(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]
            let midpoint = CGPoint(x: (previous.x + current.x) / 2,
                                   y: (previous.y + current.y) / 2)
            path.addQuadCurve(to: midpoint, control: previous)
        }
        if let last = points.last { path.addLine(to: last) }
        return path
    }

    private func area(_ points: [CGPoint], size: CGSize) -> Path {
        var path = curve(points)
        guard let first = points.first, let last = points.last else { return path }
        path.addLine(to: CGPoint(x: last.x, y: size.height))
        path.addLine(to: CGPoint(x: first.x, y: size.height))
        path.closeSubpath()
        return path
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let points = coordinates(size)
            ZStack {
                if showGrid {
                    Path { path in
                        for fraction in [0.0, 0.5, 1.0] {
                            let y = 6 + (size.height - 12) * CGFloat(fraction)
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: size.width, y: y))
                        }
                    }
                    .stroke(.white.opacity(0.10),
                            style: StrokeStyle(lineWidth: 0.7, dash: [2, 4]))
                }
                if points.count > 1 {
                    area(points, size: size)
                        .fill(LinearGradient(
                            colors: [color.opacity(0.50), color.opacity(0)],
                            startPoint: .top, endPoint: .bottom))
                        .widgetAccentable()
                    curve(points)
                        .stroke(color.opacity(0.36),
                                style: StrokeStyle(lineWidth: 4, lineCap: .round,
                                                   lineJoin: .round))
                        .blur(radius: 2.5)
                    curve(points)
                        .stroke(color,
                                style: StrokeStyle(lineWidth: 1.8, lineCap: .round,
                                                   lineJoin: .round))
                        .widgetAccentable()
                    if let last = points.last {
                        Circle().fill(color.opacity(0.25))
                            .frame(width: 12, height: 12)
                            .position(last)
                        Circle().fill(.white)
                            .frame(width: 6, height: 6)
                            .position(last)
                    }
                } else {
                    Text("—")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            String(format: String(localized: "最近 10 分钟芯片功率，均值 %@ 瓦，当前 %@ 瓦"),
                   GlassFormat.decimal(average), GlassFormat.decimal(current))
        )
    }
}

struct CoreBarsView: View {
    let values: [Double]
    let perfCount: Int
    var height: CGFloat = 30

    var body: some View {
        GeometryReader { geometry in
            let gap: CGFloat = 4
            let width = max(2, (geometry.size.width - gap * 14) / 15)
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(0..<15, id: \.self) { index in
                    let hasValue = values.indices.contains(index)
                    let load = hasValue ? min(100, max(0, values[index])) : 0
                    let color = index < perfCount ? GlassPalette.cpu : GlassPalette.power
                    ZStack(alignment: .bottom) {
                        Capsule().fill(.white.opacity(0.09))
                        if hasValue {
                            Capsule()
                                .fill(LinearGradient(
                                    colors: [color.opacity(0.60), color],
                                    startPoint: .bottom, endPoint: .top))
                                .frame(height: max(3, height * CGFloat(load) / 100))
                                .widgetAccentable()
                        }
                    }
                    .frame(width: width, height: height)
                }
            }
            .frame(width: geometry.size.width, alignment: .center)
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(values.isEmpty ? "CPU 各核心占用尚无数据" :
            "\(min(values.count, 15)) 个 CPU 核心的占用情况")
    }
}

struct UsageBar: View {
    let percent: Double
    let color: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            let fraction = CGFloat(min(100, max(0, percent))) / 100
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12))
                Capsule()
                    .fill(LinearGradient(
                        colors: [color, color.opacity(0.70)],
                        startPoint: .leading, endPoint: .trailing))
                    .frame(width: fraction <= 0 ? 0 :
                        max(height, geometry.size.width * fraction))
                    .widgetAccentable()
            }
        }
        .frame(height: height)
        .accessibilityLabel(String(format: String(localized: "已使用 %lld%%"),
                                   Int(percent)))
    }
}

struct PillView: View {
    let icon: String
    let label: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(color)
                .widgetAccentable()
            Text(LocalizedStringKey(label))
                .foregroundStyle(.secondary)
                .font(.system(size: 9))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            Text(value)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .layoutPriority(1)
        }
        .padding(.horizontal, 7)
        .frame(height: 24)
        .background(.white.opacity(0.08), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.65))
        .accessibilityElement(children: .combine)
    }
}

struct IconChip: View {
    let symbol: String
    let color: Color
    let size: CGFloat

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.50, weight: .medium))
            .foregroundStyle(color)
            .widgetAccentable()
            .frame(width: size, height: size)
            .background(color.opacity(0.18),
                        in: RoundedRectangle(cornerRadius: size * 0.30))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.30)
                    .strokeBorder(color.opacity(0.50), lineWidth: 0.8))
    }
}

// MARK: - Adaptive container and common content

struct GlassWidgetCanvas<Content: View>: View {
    let content: Content
    @Environment(\.widgetRenderingMode) private var renderingMode

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if renderingMode == .fullColor {
                    RadialGradient(
                        colors: [GlassPalette.cpu.opacity(0.18), .clear],
                        center: .center, startRadius: 0, endRadius: 120)
                        .frame(width: 240, height: 240)
                        .position(x: geometry.size.width * 0.12, y: 0)
                        .allowsHitTesting(false)
                    LinearGradient(
                        colors: [.white.opacity(0.18), .clear],
                        startPoint: .topLeading, endPoint: .bottomTrailing)
                        .frame(width: geometry.size.width * 0.40,
                               height: geometry.size.height * 0.40)
                        .allowsHitTesting(false)
                }
                content
                    .frame(width: geometry.size.width,
                           height: geometry.size.height, alignment: .topLeading)
                    .clipped()
            }
        }
        .modifier(SystemWidgetBackground())
    }
}

private struct SystemWidgetBackground: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 14, *) {
            content.containerBackground(for: .widget) {
                Color(nsColor: .windowBackgroundColor)
            }
        } else {
            content.background(Color(nsColor: .windowBackgroundColor))
        }
    }
}

private func chipBarDeepLink(_ path: String) -> URL {
    var url = URLComponents()
    url.scheme = "chipbar"
    if path.hasPrefix("disk/") {
        url.host = "disk"
        url.path = "/" + String(path.dropFirst("disk/".count))
    } else {
        url.host = path
    }
    return url.url ?? URL(string: "chipbar://main")!
}

struct WidgetSnapshotStatus: View {
    let snapshot: ChipBarSnapshot?
    let now: Date

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(snapshot == nil ? Color.secondary :
                      snapshot!.isStale(at: now) ? GlassPalette.warning : GlassPalette.online)
                .frame(width: 5, height: 5)
            Text(status)
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
        }
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(.white.opacity(0.07), in: Capsule())
        .accessibilityLabel(status)
    }

    private var status: String {
        guard let snapshot else { return String(localized: "暂无数据") }
        if snapshot.isStale(at: now) { return String(localized: "数据已过期") }
        let time = DateFormatter.localizedString(from: snapshot.timestamp,
                                                 dateStyle: .none, timeStyle: .short)
        return String(format: String(localized: "实时 %@"), time)
    }
}

struct GlassOverviewContent: View {
    let snapshot: ChipBarSnapshot?
    let now: Date
    let placeholder: Bool

    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode

    private var stale: Bool { snapshot?.isStale(at: now) == true }
    private var numberTint: Color {
        renderingMode == .fullColor ? GlassPalette.power : .primary
    }
    private var memTint: Color {
        GlassPalette.memoryColor(snapshot?.mem.percent ?? 0)
    }

    var body: some View {
        GlassWidgetCanvas {
            GeometryReader { bounds in
                Group {
                    switch family {
                    case .systemSmall:
                        small(in: bounds.size)
                    case .systemMedium:
                        medium(in: bounds.size)
                    default:
                        large(in: bounds.size)
                    }
                }
                .padding(14)
                .frame(width: bounds.size.width, height: bounds.size.height,
                       alignment: .topLeading)
                .opacity(stale ? 0.55 : 1)
                .redacted(reason: placeholder ? .placeholder : [])
            }
        }
        .widgetURL(chipBarDeepLink("main"))
        .accessibilityElement(children: .contain)
    }

    // 158 x 158. Three concentric rings; labels are necessary in accented
    // mode, where the system may erase all color distinctions.
    private func small(in size: CGSize) -> some View {
        let contentW = max(1, size.width - 28)
        let contentH = max(1, size.height - 28)
        let diameter = min(100, max(72, contentH - 30), contentW - 4)
        return VStack(spacing: 1) {
            ZStack {
                concentricRing(percent: snapshot?.cpu.percent, tint: GlassPalette.cpu,
                               diameter: diameter, lineWidth: 7)
                concentricRing(percent: snapshot?.gpu.percent, tint: GlassPalette.gpu,
                               diameter: diameter * 0.80, lineWidth: 7)
                concentricRing(percent: snapshot?.mem.percent, tint: memTint,
                               diameter: diameter * 0.60, lineWidth: 7)
                GlassNumberText(text: number(snapshot?.chipPower), unit: "W",
                                size: 15.5, tint: numberTint)
                    .frame(width: diameter * 0.55)
            }
            .frame(height: diameter)
            Spacer(minLength: 1)
            HStack(alignment: .top, spacing: 2) {
                miniLegend("CPU", snapshot?.cpu.percent, GlassPalette.cpu)
                miniLegend("GPU", snapshot?.gpu.percent, GlassPalette.gpu)
                miniLegend("内存", snapshot?.mem.percent, memTint)
            }
            .frame(height: 26)
        }
        .frame(width: contentW, height: contentH)
    }

    private func concentricRing(percent: Double?, tint: Color,
                                diameter: CGFloat, lineWidth: CGFloat) -> some View {
        Circle()
            .stroke(.white.opacity(0.11), lineWidth: lineWidth)
            .overlay {
                Circle()
                    .trim(from: 0, to: CGFloat(min(100, max(0, percent ?? 0)) / 100))
                    .stroke(
                        LinearGradient(colors: [tint, tint.opacity(0.68), .white.opacity(0.65)],
                                       startPoint: .bottomLeading, endPoint: .topTrailing),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: tint.opacity(0.67), radius: 3)
                    .widgetAccentable()
            }
            .frame(width: diameter, height: diameter)
            .accessibilityLabel("\(GlassFormat.decimal(percent, precision: 0))%")
    }

    private func miniLegend(_ name: String, _ value: Double?, _ tint: Color) -> some View {
        VStack(spacing: 1) {
            HStack(spacing: 3) {
                Circle().fill(tint).frame(width: 5, height: 5)
                    .widgetAccentable()
                Text(GlassFormat.decimal(value, precision: 0) + "%")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.67)
            }
            Text(LocalizedStringKey(name))
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var powerHero: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("芯片总功率")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            GlassNumberText(text: number(snapshot?.chipPower), unit: "W",
                            size: 30, tint: numberTint)
            Text("均值 \(number(snapshot?.avgPower)) W · 内部 \(number(snapshot?.internalPower)) W")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.60)
        }
    }

    private func medium(in size: CGSize) -> some View {
        let w = size.width - 28
        let h = size.height - 28
        let left = max(112, w * 0.48)
        let right = max(1, w - left - 8)
        // Header + power labels + trend must all fit inside the system's
        // compact 158pt high medium widget, including safe text scaling.
        let trendHeight = max(18, min(38, h - 94))
        let ringColumnWidth = max(1, (right - 6) / 3)
        return HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    IconChip(symbol: "waveform.path.ecg",
                             color: GlassPalette.power, size: 24)
                    Text("芯片总功率")
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                }
                powerHero
                SparklineView(values: snapshot?.powerSeries ?? [],
                              color: GlassPalette.power, showGrid: true,
                              average: snapshot?.avgPower, current: snapshot?.chipPower)
                    .frame(height: trendHeight)
            }
            .frame(width: left, alignment: .leading)

            VStack(spacing: 5) {
                HStack(alignment: .top, spacing: 3) {
                    mediumRing("CPU", snapshot?.cpu.percent,
                               watts: snapshot?.cpu.watts, detail: temperature(snapshot?.cpu.tempC),
                               tint: GlassPalette.cpu, width: ringColumnWidth)
                    mediumRing("GPU", snapshot?.gpu.percent,
                               watts: snapshot?.gpu.watts, detail: temperature(snapshot?.gpu.tempC),
                               tint: GlassPalette.gpu, width: ringColumnWidth)
                    mediumRing("内存", snapshot?.mem.percent,
                               watts: nil, detail: capacity(snapshot?.mem.totalGB),
                               tint: memTint, width: ringColumnWidth)
                }
                Divider().overlay(.white.opacity(0.12))
                HStack(spacing: 4) {
                    PillView(icon: "fanblades", label: "风扇",
                             value: rpm(snapshot?.fanRPM), color: GlassPalette.fan)
                    PillView(icon: "sparkles", label: "ANE",
                             value: GlassFormat.power(snapshot?.aneWatts),
                             color: GlassPalette.ane)
                }
            }
            .frame(width: right, alignment: .top)
        }
        .frame(width: w, height: h, alignment: .topLeading)
    }

    private func mediumRing(_ name: String, _ percent: Double?, watts: Double?,
                            detail: String, tint: Color, width: CGFloat) -> some View {
        VStack(spacing: 2) {
            RingView(percent: percent, color: tint, lineWidth: 5.5,
                     label: name, diameter: 40, watts: watts,
                     tempC: name == "CPU" ? snapshot?.cpu.tempC :
                             name == "GPU" ? snapshot?.gpu.tempC : nil)
            Text(LocalizedStringKey(name))
                .font(.system(size: 8.5))
                .foregroundStyle(.secondary)
            Text(watts == nil ? capacity(snapshot?.mem.usedGB) : GlassFormat.power(watts))
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .lineLimit(1).minimumScaleFactor(0.60)
            Text(detail)
                .font(.system(size: 8.5))
                .foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.60)
        }
        .frame(width: width)
    }

    // Keep the large WidgetKit layout in small, independently type-checked
    // sections. A single deeply nested ViewBuilder exceeded the Swift 5
    // type-checker's time budget on the Xcode 26 release runner.
    private func large(in size: CGSize) -> some View {
        let w = size.width - 28
        let h = size.height - 28
        let tight = h < 310
        return VStack(alignment: .leading, spacing: tight ? 3 : 5) {
            largeHeader
            largePower(width: w, tight: tight)
            Divider()
            largeRings(tight: tight)
            largeCoreHeader
            CoreBarsView(values: snapshot?.cores ?? [],
                         perfCount: snapshot?.performanceCoreCount ?? 10,
                         height: tight ? 22 : 30)
            largeStorage
            Spacer(minLength: 0)
            largeFooter
        }
        .frame(width: w, height: h, alignment: .topLeading)
    }

    private var largeHeader: some View {
        HStack(spacing: 6) {
            IconChip(symbol: "waveform.path.ecg",
                     color: GlassPalette.power, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text("ChipBar")
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(1)
                Text(snapshot?.chipName ?? "Apple Silicon")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.65)
            }
            Spacer(minLength: 1)
            WidgetSnapshotStatus(snapshot: snapshot, now: now)
        }
    }

    private func largePower(width: CGFloat, tight: Bool) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("芯片总功率")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                GlassNumberText(text: number(snapshot?.chipPower),
                                unit: "W", size: tight ? 33 : 38, tint: numberTint)
                Text("均值 \(number(snapshot?.avgPower)) W · 峰值 \(number(snapshot?.peakPower)) W")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.60)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            SparklineView(values: snapshot?.powerSeries ?? [],
                          color: GlassPalette.power, showGrid: true,
                          average: snapshot?.avgPower, current: snapshot?.chipPower)
                .frame(width: width * 0.50, height: tight ? 39 : 52)
        }
    }

    private func largeRings(tight: Bool) -> some View {
        HStack(alignment: .top, spacing: 5) {
            largeRing("CPU", snapshot?.cpu.percent, snapshot?.cpu.watts,
                      detail: temperature(snapshot?.cpu.tempC),
                      tint: GlassPalette.cpu, diameter: tight ? 42 : 48)
            largeRing("GPU", snapshot?.gpu.percent, snapshot?.gpu.watts,
                      detail: temperature(snapshot?.gpu.tempC),
                      tint: GlassPalette.gpu, diameter: tight ? 42 : 48)
            largeRing("内存", snapshot?.mem.percent, nil,
                      detail: "共 " + capacity(snapshot?.mem.totalGB),
                      tint: memTint, diameter: tight ? 42 : 48)
        }
    }

    private var largeCoreHeader: some View {
        // Compute localized content before entering ViewBuilder; combining
        // nested optional.map, String(localized:) and Text overload resolution
        // in one HStack exhausted the release compiler's type-check budget.
        let performanceCount: String
        let efficiencyCount: String
        if let snapshot {
            performanceCount = String(snapshot.performanceCoreCount)
            efficiencyCount = String(max(0, snapshot.cores.count - snapshot.performanceCoreCount))
        } else {
            performanceCount = "—"
            efficiencyCount = "—"
        }
        let performanceLabel = "● " + String(localized: "性能核") + " " + performanceCount
        let efficiencyLabel = "● " + String(localized: "超级核") + " " + efficiencyCount
        return HStack(spacing: 5) {
            Text("CPU 各核心")
                .font(.system(size: 9, weight: .semibold))
            Spacer(minLength: 1)
            Text(performanceLabel)
                .foregroundStyle(.secondary)
                .font(.system(size: 8))
                .lineLimit(1)
            Text(efficiencyLabel)
                .foregroundStyle(.secondary)
                .font(.system(size: 8))
                .lineLimit(1)
        }
    }

    private var largeStorage: some View {
        HStack(alignment: .top, spacing: 8) {
            if let volumes = snapshot?.volumes, !volumes.isEmpty {
                ForEach(Array(volumes.prefix(2))) { volume in
                    StorageVolumeRow(volume: volume, enlarged: false)
                        .frame(maxWidth: .infinity)
                }
            } else {
                Text("储存空间 —")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var largeFooter: some View {
        HStack(spacing: 4) {
            PillView(icon: "fanblades", label: "风扇",
                     value: rpm(snapshot?.fanRPM), color: GlassPalette.fan)
            PillView(icon: "sparkles", label: "ANE",
                     value: GlassFormat.power(snapshot?.aneWatts), color: GlassPalette.ane)
            Link(destination: chipBarDeepLink("power")) {
                PillView(icon: "bolt.fill", label: "内部",
                         value: GlassFormat.power(snapshot?.internalPower),
                         color: GlassPalette.power)
            }
            .buttonStyle(.plain)
        }
    }

    private func largeRing(_ name: String, _ percent: Double?, _ watts: Double?,
                           detail: String, tint: Color, diameter: CGFloat) -> some View {
        VStack(spacing: 2) {
            RingView(percent: percent, color: tint, lineWidth: 6,
                     label: name, diameter: diameter, watts: watts,
                     tempC: name == "CPU" ? snapshot?.cpu.tempC :
                             name == "GPU" ? snapshot?.gpu.tempC : nil,
                     fontSize: 13)
            Text(name + (watts == nil ? " " + capacity(snapshot?.mem.usedGB) :
                         " " + GlassFormat.power(watts)))
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .lineLimit(1).minimumScaleFactor(0.60)
            Text(detail)
                .font(.system(size: 8.5))
                .foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity)
    }

    private func number(_ value: Double?) -> String {
        GlassFormat.decimal(value)
    }
    private func temperature(_ value: Double?) -> String {
        guard value != nil else { return "—" }
        return GlassFormat.decimal(value) + "°"
    }
    private func capacity(_ value: Double?) -> String {
        guard value != nil else { return "—" }
        return GlassFormat.decimal(value) + " GB"
    }
    private func rpm(_ value: Int?) -> String {
        guard let value else { return "—" }
        return String(value) + " RPM"
    }
}

struct StorageVolumeRow: View {
    let volume: ChipBarSnapshot.Volume
    let enlarged: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: enlarged ? 6 : 3) {
            HStack(spacing: 3) {
                Text(volume.name)
                    .font(.system(size: enlarged ? 11 : 9, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                    .minimumScaleFactor(0.65)
                Spacer(minLength: 1)
                Text(String(format: String(localized: "已用 %@%%"),
                            String(Int(volume.usedPercent))))
                    .font(.system(size: 8.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            let available = GlassFormat.capacity(volume.freeBytes)
            if enlarged {
                GlassNumberText(text: available.number, unit: available.unit,
                                size: 24, tint: .primary)
            } else {
                Text(String(format: String(localized: "%@ %@ 可用"),
                            available.number, available.unit))
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.65)
            }
            UsageBar(percent: volume.usedPercent, color: GlassPalette.cpu)
            Text("读 \(GlassFormat.decimal(volume.readMBs)) · 写 \(GlassFormat.decimal(volume.writeMBs)) MB/s")
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct GlassStorageContent: View {
    let snapshot: ChipBarSnapshot?
    let selectedVolume: String?
    let now: Date
    let placeholder: Bool

    @Environment(\.widgetRenderingMode) private var renderingMode

    private var volumes: [ChipBarSnapshot.Volume] {
        guard let snapshot else { return [] }
        if let name = selectedVolume, !name.isEmpty,
           let match = snapshot.volumes.first(where: { $0.name == name }) {
            return [match]
        }
        return Array(snapshot.volumes.prefix(2))
    }

    var body: some View {
        GlassWidgetCanvas {
            GeometryReader { bounds in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 5) {
                        IconChip(symbol: "externaldrive", color: GlassPalette.cpu, size: 20)
                        Text("储存空间")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        WidgetSnapshotStatus(snapshot: snapshot, now: now)
                    }
                    Spacer(minLength: 1)
                    if volumes.isEmpty {
                        Text("—")
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    } else {
                        ForEach(volumes) { volume in
                            Link(destination: chipBarDeepLink("disk/" + volume.name)) {
                                StorageVolumeRow(volume: volume,
                                                 enlarged: volumes.count == 1)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Spacer(minLength: 1)
                }
                .padding(14)
                .frame(width: bounds.size.width, height: bounds.size.height,
                       alignment: .topLeading)
                .opacity(snapshot?.isStale(at: now) == true ? 0.55 : 1)
                .redacted(reason: placeholder ? .placeholder : [])
            }
        }
        .widgetURL(chipBarDeepLink("disk/" + (selectedVolume ?? volumes.first?.name ?? "")))
    }
}
