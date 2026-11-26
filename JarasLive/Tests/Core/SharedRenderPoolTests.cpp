#include "../../Core/Audio/SharedRenderPool.hpp"
#include <thread>
#include <iostream>

struct State {
    static inline std::atomic<unsigned> alive{0};
    int value = 0;
    explicit State(int initial) : value(initial) { ++alive; }
    ~State() { --alive; }
};
int main() {
    using Pool = catlive::audio::SharedRenderPool<State, 64>;
    Pool pool;
    assert(pool.reserve(64, 0));
    auto first = pool.acquire(); first->value = 17;
    const auto old = first.handle();
    auto second = pool.retain(old);
    assert(second && second->value == 17 && !pool.makeExclusive(first));
    auto next = pool.acquire(); next->value = 29;
    first.publishSuccessor(next);
    auto hit = second.cachedSuccessor(); assert(hit && hit->value == 29);
    hit.reset(); next.reset(); assert(!second.cachedSuccessor());
    second.reset();
    assert(pool.makeExclusive(first) && !pool.retain(old));
    first.reset();
    std::atomic<uint64_t> published{0};
    std::atomic<bool> done{false};
    std::thread reader([&] {
        while (!done.load()) {
            auto value = pool.retain(published.load());
            if (value) { const auto saved = value->value; std::this_thread::yield(); assert(value->value == saved); }
        }
    });
    for (int i = 0; i < 100000; ++i) {
        auto value = pool.acquire(); assert(value); value->value = i;
        published.store(value.handle());
        if (pool.makeExclusive(value)) value->value = -i;
    }
    done.store(true); reader.join();
    std::array<Pool::Lease, 64> held;
    for (auto &value : held) { value = pool.acquire(); assert(value); }
    assert(!pool.acquire());
    for (auto &value : held) value.reset();
    auto sounding = pool.acquire(); sounding->value = 71;
    auto shared = pool.retain(sounding.handle());
    pool.trimUnusedIfUnshared(false);
    assert(State::alive == 64); // A shared converter may need to fork on render.
    shared.reset();
    auto spare = pool.acquire(); const auto stale = spare.handle(); spare.reset();
    pool.trimUnusedIfUnshared(false);
    assert(State::alive == 1 && !pool.acquire() && sounding->value == 71);
    pool.restoreUnused(64, 9);
    assert(State::alive == 64 && !pool.retain(stale));
    for (size_t index = 0; index < held.size() - 1; ++index) {
        held[index] = pool.acquire(); assert(held[index] && held[index]->value == 9);
    }
    assert(!pool.acquire() && sounding->value == 71);
    for (auto &value : held) value.reset();
    sounding.reset(); pool.trimUnusedIfUnshared(true);
    assert(State::alive == 0 && !pool.acquire());
    pool.restoreUnused(2, 23);
    assert(State::alive == 2);
    auto restored = pool.acquire(); assert(restored && restored->value == 23 && !pool.retain(stale));
    std::cout << "SHARED_RENDER_POOL_GENERATIONS_EXCLUSIVE_WEAK_CACHE_CONCURRENCY_OK\n";
    std::cout << "SHARED_RENDER_POOL_IDLE_DSP_TRIM_RESTORE_NO_STALE_HANDLES_OK\n";
}
