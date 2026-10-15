#pragma once
#include "Common.h"
#include <psapi.h>
namespace catlive {
class ResourceUsage final {
  public:
    std::optional<double> cpu, ram;
    uint64 samples = 0;
    static double cpuPercent(double deltaCPU, double deltaWall, int processors) {
        return deltaWall > 0 ? jlimit(0., 100., 100 * deltaCPU / deltaWall / std::max(1, processors)) : 0;
    }
    bool sample() {
        const double now = Time::getMillisecondCounterHiRes() / 1000.;
        if (previousWall >= 0 && now - previousWall < 1.) return false;
        FILETIME created{}, exited{}, kernel{}, user{};
        const auto seconds = [](FILETIME t) { return ((uint64(t.dwHighDateTime) << 32) | t.dwLowDateTime) * 1e-7; };
        if (GetProcessTimes(GetCurrentProcess(), &created, &exited, &kernel, &user)) {
            const double total = seconds(kernel) + seconds(user);
            if (previousCPU >= 0) cpu = cpuPercent(total - previousCPU, now - previousWall, (int)GetActiveProcessorCount(ALL_PROCESSOR_GROUPS));
            previousCPU = total;
        } else { cpu.reset(); previousCPU = -1; }
        previousWall = now;
        PROCESS_MEMORY_COUNTERS_EX memory{}; memory.cb = sizeof(memory);
        MEMORYSTATUSEX system{}; system.dwLength = sizeof(system);
        // Windows physical process working set is the platform equivalent used
        // here; Darwin phys_footprint has different shared/compressed accounting.
        if (GetProcessMemoryInfo(GetCurrentProcess(), reinterpret_cast<PROCESS_MEMORY_COUNTERS *>(&memory), sizeof(memory)) && GlobalMemoryStatusEx(&system) && system.ullTotalPhys)
            ram = jlimit(0., 100., 100. * memory.WorkingSetSize / system.ullTotalPhys);
        else ram.reset();
        ++samples; return true;
    }
    static String percent(std::optional<double> value) { return value ? String(*value, 1) + "%" : String::fromUTF8("—%"); }
  private:
    double previousWall = -1, previousCPU = -1;
};
}
