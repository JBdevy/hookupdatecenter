#include "../../Apple/Bridge/JarasEffects.mm"
#include <cassert>
#include <iostream>

int main() {
    @autoreleasepool {
        PreparedTimingState state;
        auto publish = [&](double rate, double pitch) {
            state.beginUpdates();
            for (uint64_t id = 1; id <= 200; ++id) state.set(id, {1, rate, pitch});
            state.endUpdates();
        };
        auto check = [&](double rate, double pitch) {
            for (uint64_t id = 1; id <= 200; ++id) {
                double r = 0, p = 0;
                assert(state.read(id, 1, r, p) && r == rate && p == pitch);
            }
        };
        publish(1, 0);
        state.beginRender();
        state.beginUpdates();
        for (uint64_t id = 1; id <= 100; ++id) state.set(id, {1, 1.25, 7});
        check(1, 0); state.endRender();
        state.beginRender(); check(1, 0);
        for (uint64_t id = 101; id <= 200; ++id) state.set(id, {1, 1.25, 7});
        state.endUpdates();
        check(1, 0); // Even a committed edit cannot change an active graph pull.
        state.endRender(); state.beginRender(); check(1.25, 7); state.endRender();

        // A slow producer and a continuously rendering graph must never hear
        // a partially published edit, even across many discarded publications.
        std::atomic<bool> done{false};
        std::thread producer([&] {
            for (unsigned n = 1; n <= 2000; ++n) publish(1 + double(n) / 10000, double(n % 12));
            done.store(true);
        });
        unsigned reads = 0;
        do {
            state.beginRender();
            double rate = 0, pitch = 0;
            assert(state.read(1, 1, rate, pitch)); check(rate, pitch);
            state.endRender(); ++reads;
        } while (!done.load());
        producer.join();
        state.beginRender(); check(1.2, 8);
        double rate = 2, pitch = 3;
        assert(!state.read(1, 2, rate, pitch) && rate == 2 && pitch == 3);
        state.endRender();
        state.remove(1); state.beginRender(); assert(!state.read(1, 1, rate, pitch)); state.endRender();
        std::cout << "PREPARED_TIMING_200_VOICES_ATOMIC_EDITS_REPREPARE_OK reads=" << reads << '\n';
    }
}
