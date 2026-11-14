#include "../../Core/Audio/SharedRenderPool.hpp"
#include <thread>
#include <iostream>

struct State { int value = 0; explicit State(int initial) : value(initial) {} };
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
    std::cout << "SHARED_RENDER_POOL_GENERATIONS_EXCLUSIVE_WEAK_CACHE_CONCURRENCY_OK\n";
}
