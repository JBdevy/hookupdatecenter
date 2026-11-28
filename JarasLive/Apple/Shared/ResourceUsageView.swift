import SwiftUI
import Darwin

enum ResourceMemoryScope { case application, device }

@MainActor private final class ResourceUsage: ObservableObject {
    @Published private(set) var cpu: Double?
    @Published private(set) var ram: Double?
    @Published private(set) var totalRam: Double?
    @Published private(set) var disk: Double?
    let memoryScope: ResourceMemoryScope
    let showsTotalMemory: Bool
    init(memoryScope: ResourceMemoryScope, showsTotalMemory: Bool) {
        self.memoryScope = memoryScope
        self.showsTotalMemory = showsTotalMemory
    }
    private var previous: (wall: Double, cpu: Double)?
    func sample() {
        var usage = rusage()
        if getrusage(RUSAGE_SELF, &usage) == 0 {
            let total = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
                + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
            let now = ProcessInfo.processInfo.systemUptime
            if let previous, now > previous.wall {
                cpu = min(100, max(0, (total - previous.cpu) / (now - previous.wall) * 100 / Double(max(1, ProcessInfo.processInfo.activeProcessorCount))))
            }
            previous = (now, total)
        } else { cpu = nil }
        if memoryScope == .device || showsTotalMemory {
            let deviceRam = Self.deviceMemoryPercent()
            if showsTotalMemory { totalRam = deviceRam }
            if memoryScope == .device { ram = deviceRam; return }
        }
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            ram = min(100, max(0, Double(info.phys_footprint) / Double(ProcessInfo.processInfo.physicalMemory) * 100))
        } else { ram = nil }

    }
    static func deviceMemoryPercent() -> Double? {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var pageSize: vm_size_t = 0
        guard host_page_size(host, &pageSize) == KERN_SUCCESS else { return nil }
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        guard result == KERN_SUCCESS, total > 0 else { return nil }
        // Darwin includes speculative pages in free_count; do not subtract them twice.
        let free = Double(info.free_count) * Double(pageSize)
        return min(100, max(0, (total - free) / total * 100))
    }
    func run() async {
        previous = nil
        while !Task.isCancelled {
            sample()
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
        }
    }
    func runDisk() async {
        var previous: (time: Double, occupied: Int64)?
        while !Task.isCancelled {
            let occupied = JarasAudioDiskOccupiedNanoseconds()
            if occupied >= 0 {
                let time = ProcessInfo.processInfo.systemUptime
                if let previous, time > previous.time {
                    let value = min(100, max(0, Double(occupied - previous.occupied) / 10_000_000 / (time - previous.time))).rounded()
                    if value != disk { disk = value }
                }
                previous = (time, occupied)
            }
            do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
        }
    }
}

@MainActor final class TransportMIDIActivity: ObservableObject {
    static let shared = TransportMIDIActivity()
    @Published private(set) var active = false
    private var lastEvent = 0.0
    private var release: Task<Void, Never>?

    func receive() {
        lastEvent = ProcessInfo.processInfo.systemUptime
        guard !active else { return }
        active = true
        release = Task {
            while !Task.isCancelled {
                let remaining = 0.20 - (ProcessInfo.processInfo.systemUptime - lastEvent)
                if remaining <= 0 { active = false; release = nil; return }
                do { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
                catch { return }
            }
        }
    }
}

enum TransportPanelColor: String, CaseIterable {
    static let key = "jaras.transport.panelColor"
    static let defaultColor: Self = .darkGray
    case darkGray, lightGray, purple, black

    static func resolved(_ preference: String) -> Self {
        Self(rawValue: preference) ?? defaultColor
    }

    var title: String {
        switch self {
        case .darkGray: return "Cinza Dark"
        case .lightGray: return "Cinza Light"
        case .purple: return "Purple"
        case .black: return "Black"
        }
    }

    var topColor: Color {
        switch self {
        case .darkGray: return Color(hex: 0x262626)
        case .lightGray: return Color(hex: 0x555555)
        case .purple: return JarasTheme.proTransportTop
        case .black: return .black
        }
    }

    var gradient: Gradient {
        switch self {
        case .darkGray: return Gradient(colors: JarasTheme.desktopTransportGradient)
        case .lightGray: return Gradient(colors: [Color(hex: 0x555555), Color(hex: 0x414141)])
        case .purple: return JarasTheme.proTransportGradient
        case .black: return Gradient(colors: [.black, .black])
        }
    }
}

struct TransportResourceMeters: View {
    enum Placement {
        case desktop, remote, nativeTransport, nativeFooter
    }

    @AppStorage(TransportPanelColor.key) private var panelColor = ""
    static let width: CGFloat = 132
    var placement: Placement = .desktop
    @StateObject private var usage = ResourceUsage(memoryScope: .application, showsTotalMemory: false)
    private var compactLabels: Bool { placement == .nativeTransport || placement == .nativeFooter }
    private var showsDisk: Bool { placement == .desktop || placement == .nativeFooter }

    var body: some View {
        Group {
            switch placement {
            case .desktop:
                HStack(spacing: 8) {
                    cpuMeter
                    ramMeter
                    diskMeter
                    midiMeter
                }
            case .remote, .nativeTransport:
                HStack(spacing: 9) {
                    cpuMeter
                    ramMeter
                }
            case .nativeFooter:
                HStack(spacing: 9) {
                    diskMeter
                    midiMeter
                }
            }
        }.frame(width: placement == .desktop ? 248 : Self.width).contentShape(Rectangle())
            .contextMenu {
                if placement == .desktop || placement == .nativeTransport {
                    ForEach(TransportPanelColor.allCases, id: \.self) { color in
                        Button { panelColor = color.rawValue } label: {
                            Label(color.title, systemImage: TransportPanelColor.resolved(panelColor) == color ? "checkmark" : "circle")
                        }
                    }
                }
            }
            .task { if placement != .nativeFooter { await usage.run() } }
            .task { if showsDisk { await usage.runDisk() } }
    }

    private var cpuMeter: some View {
        Self.meter("CPU", value: usage.cpu, help: "CPU used by CatLive", compact: compactLabels)
    }
    private var ramMeter: some View {
        Self.meter("RAM", value: usage.ram, help: "RAM used by CatLive", compact: compactLabels)
    }
    private var diskMeter: some View {
        Self.meter("HD", value: usage.disk, help: "Audio disk read and write load", compact: compactLabels, warningAt: 90)
    }
    private var midiMeter: some View { MIDIMeter(compact: compactLabels) }

    private struct MIDIMeter: View {
        @ObservedObject private var activity = TransportMIDIActivity.shared
        let compact: Bool

        var body: some View {
            TransportResourceMeters.meter("MIDI", value: activity.active ? 100 : 0,
                                          help: "MIDI input activity", compact: compact)
        }
    }
    private static func meter(_ label: String, value: Double?, help: String, compact: Bool,
                              warningAt: Double = .infinity) -> some View {
        HStack(spacing: 4) {
            Text(verbatim: label)
                .font(compact ? .system(size: 7, weight: .semibold) : .jarasSystem(size: 8, weight: .semibold))
                .lineLimit(1).minimumScaleFactor(0.8)
                .foregroundStyle(JarasTheme.secondary).frame(width: 23, alignment: .leading)
            Capsule().fill(Color.white.opacity(0.15)).frame(height: 4)
                .overlay(alignment: .leading) {
                    if let value {
                        Capsule().fill(value >= warningAt ? JarasTheme.liveOffRed : JarasTheme.green)
                            .frame(width: (Self.width - 9 - 54) / 2 * value / 100)
                    }
                }
        }.frame(height: 10)
            .accessibilityElement(children: .ignore).accessibilityLabel(Text(verbatim: label))
            .accessibilityValue(Text(verbatim: value.map { "\(Int($0.rounded()))%" } ?? "—"))
            .jarasHelp(help)
    }
}
struct ResourceUsageView: View {
    @StateObject private var usage: ResourceUsage
    init(memoryScope: ResourceMemoryScope = .application, showsTotalMemory: Bool = false) {
        _usage = StateObject(wrappedValue: ResourceUsage(memoryScope: memoryScope, showsTotalMemory: showsTotalMemory))
    }
    var body: some View {
        HStack(spacing: 14) {
            indicator("CPU", value: usage.cpu)
            indicator("RAM", value: usage.ram).jarasHelp(usage.memoryScope == .device ? "Device RAM in use" : "RAM used by CatLive")
            if usage.showsTotalMemory {
                indicator("T-Ram", value: usage.totalRam).jarasHelp("Device RAM in use")
            }
        }.monospacedDigit().foregroundStyle(JarasTheme.secondary)
            .task { await usage.run() }
    }
    private func indicator(_ label: String, value: Double?) -> some View {
        // Reserve the largest reading, including the initial unavailable value.
        // The overlay updates without changing the footer's intrinsic width.
        Text(verbatim: "\(label) 100.0%").hidden()
            .overlay(alignment: .leading) {
                Text(verbatim: "\(label) \(percent(value))").lineLimit(1)
            }
            .fixedSize(horizontal: true, vertical: false)
    }
    private func percent(_ value: Double?) -> String {
        value.map { String(format: "%.1f%%", $0) } ?? "—%"
    }
}
