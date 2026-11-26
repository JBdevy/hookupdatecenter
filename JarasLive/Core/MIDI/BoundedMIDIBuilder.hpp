#pragma once
#include <algorithm>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace jaras {
// The sink is prepared by its owner. Only short MIDI is accepted, so an event
// limit also bounds encoded storage. One overflow silences the entire pending
// block; later appends cannot resurrect a note after that panic.
template<std::size_t Events = 4096, std::size_t Visits = 65536>
class BoundedMIDIBuilder {
public:
    static constexpr std::size_t maximumEvents = Events, maximumVisits = Visits, panicEvents = 48;
    static_assert(Events >= panicEvents && Visits > 0);
    static_assert(std::atomic<std::uint64_t>::is_always_lock_free);
    void beginBlock() noexcept { count = visits = 0; failed = false; }
    bool overflowed() const noexcept { return failed; }
    std::size_t size() const noexcept { return count; }
    std::uint64_t overflows() const noexcept { return failures.load(std::memory_order_relaxed); }
    template<class Sink> void panic(Sink& sink, bool report = true) noexcept {
        if (failed) return;
        failed = true;
        if (report) failures.fetch_add(1, std::memory_order_relaxed);
        sink.clear();
        for (unsigned channel = 0; channel < 16; ++channel)
            for (const unsigned control : {64u, 120u, 123u}) {
                const std::uint8_t bytes[]{std::uint8_t(0xb0 | channel), std::uint8_t(control), 0};
                sink.add(bytes, 3, 0);
            }
        count = panicEvents;
    }
    template<class Sink> bool inspect(Sink& sink) noexcept {
        if (failed) return false;
        if (visits == Visits) { panic(sink); return false; }
        ++visits; return true;
    }
    template<class Sink> bool append(Sink& sink, const std::uint8_t* bytes, std::size_t size, int offset) noexcept {
        if (failed) return false;
        if (!bytes || size == 0 || size > 3 || count == Events) { panic(sink); return false; }
        sink.add(bytes, size, offset); ++count; return true;
    }
private:
    std::size_t count = 0, visits = 0;
    bool failed = false;
    std::atomic<std::uint64_t> failures{0};
};

// Balanced interval index, allocated with the sequence. Old/future notes are
// pruned when chasing a seek, avoiding a full-score scan for a sparse long song.
// Notes must be sorted by start before prepare(). The visit budget still bounds
// adversarial overlap and scope-filtered notes.
class MIDINoteChaseIndex {
public:
    template<class Notes> void prepare(const Notes& notes) {
        maximumEnd.resize(notes.size());
        const auto build = [&](const auto& self, std::size_t first, std::size_t last) -> double {
            if (first == last) return -1.;
            const auto middle = first + (last - first) / 2;
            return maximumEnd[middle] = std::max({notes[middle].end,
                self(self, first, middle), self(self, middle + 1, last)});
        };
        build(build, 0, notes.size());
    }
    template<class Notes, class Inspect, class Emit>
    bool visit(const Notes& notes, double at, Inspect&& inspect, Emit&& emit) const noexcept {
        if (maximumEnd.size() != notes.size()) return false;
        const auto walk = [&](const auto& self, std::size_t first, std::size_t last) -> bool {
            if (first == last) return true;
            if (!inspect()) return false;
            const auto middle = first + (last - first) / 2;
            if (maximumEnd[middle] <= at + 1e-9) return true;
            if (!self(self, first, middle)) return false;
            const auto& note = notes[middle];
            if (note.start >= at - 1e-9) return true;
            if (note.end > at + 1e-9 && !emit(note)) return false;
            return self(self, middle + 1, last);
        };
        return walk(walk, 0, notes.size());
    }
private:
    std::vector<double> maximumEnd;
};
} // namespace jaras
