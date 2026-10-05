import SwiftUI
import Darwin

enum ResourceMemoryScope { case application, device }

@MainActor private final class ResourceUsage: ObservableObject {
    @Published private(set) var cpu: Double?
    @Published private(set) var ram: Double?
    let memoryScope: ResourceMemoryScope
    init(memoryScope: ResourceMemoryScope) { self.memoryScope = memoryScope }
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
        if memoryScope == .device {
            ram = Self.deviceMemoryPercent()
            return
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
}
struct ResourceUsageView: View {
    @StateObject private var usage: ResourceUsage
    init(memoryScope: ResourceMemoryScope = .application) {
        _usage = StateObject(wrappedValue: ResourceUsage(memoryScope: memoryScope))
    }
    var body: some View {
        HStack(spacing: 14) {
            Text("CPU \(percent(usage.cpu))")
            Text("RAM \(percent(usage.ram))").jarasHelp(usage.memoryScope == .device ? "Device RAM in use" : "RAM used by CatLive")
        }.monospacedDigit().foregroundStyle(JarasTheme.secondary)
            .task { await usage.run() }
    }
    private func percent(_ value: Double?) -> String {
        value.map { String(format: "%.1f%%", $0) } ?? "—%"
    }
}
