import SwiftUI
import Darwin

@MainActor private final class ResourceUsage: ObservableObject {
    @Published private(set) var cpu: Double?
    @Published private(set) var ram: Double?
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
    func run() async {
        previous = nil
        while !Task.isCancelled {
            sample()
            do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
        }
    }
}
struct ResourceUsageView: View {
    @StateObject private var usage = ResourceUsage()
    var body: some View {
        HStack(spacing: 14) {
            Text("CPU \(percent(usage.cpu))")
            Text("RAM \(percent(usage.ram))").jarasHelp("RAM used by CatLive")
        }.monospacedDigit().foregroundStyle(JarasTheme.secondary)
            .task { await usage.run() }
    }
    private func percent(_ value: Double?) -> String {
        value.map { String(format: "%.1f%%", $0) } ?? "—%"
    }
}
