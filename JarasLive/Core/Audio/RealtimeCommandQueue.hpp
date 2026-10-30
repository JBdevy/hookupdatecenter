#pragma once

#include <array>
#include <atomic>
#include <cstddef>
#include <deque>
#include <utility>
#include <memory>
#include <type_traits>
#include <vector>

namespace catlive::audio {
// One serialized control producer and one serialized audio consumer. Consumer
// ownership may move to control only after the device callback is excluded.
// Blocks are owned, allocated, recycled and destroyed exclusively by control.
// The audio side neither waits nor allocates, even when control outpaces it.
// This bounds work per consume(), not queued memory: control-side storage can
// grow to preserve ordered commands while a device is stopped/unavailable.
template<class T, std::size_t BlockSize = 256, std::size_t SpareBlocks = 4>
class RealtimeCommandQueue final {
    static_assert(BlockSize > 0);
    static_assert(std::is_trivially_copyable_v<T> && std::is_trivially_destructible_v<T>);
    static_assert(std::is_nothrow_copy_assignable_v<T>);
    struct Block {
        std::array<T, BlockSize> values{};
        std::atomic<std::size_t> published{0};
        std::atomic<Block*> next{nullptr};
        void reset() noexcept {
            published.store(0, std::memory_order_relaxed);
            next.store(nullptr, std::memory_order_relaxed);
        }
    };
    static_assert(std::atomic<Block*>::is_always_lock_free);
    static_assert(std::atomic<std::size_t>::is_always_lock_free);
public:
    RealtimeCommandQueue() {
        spare_.reserve(SpareBlocks);
        blocks_.push_back(std::make_unique<Block>());
        for (std::size_t i = 0; i < SpareBlocks; ++i)
            spare_.push_back(std::make_unique<Block>());
        writer_ = reader_ = blocks_.front().get();
        readerPosition_.store(reader_, std::memory_order_relaxed);
    }
    RealtimeCommandQueue(const RealtimeCommandQueue&) = delete;
    RealtimeCommandQueue& operator=(const RealtimeCommandQueue&) = delete;

    // Control only. Never consumes commands or takes the device callback lock.
    // Allocation failure propagates on control before the command is published.
    void push(const T& command) {
        collectRetired();
        if (writeIndex_ == BlockSize) {
            std::unique_ptr<Block> next;
            if (spare_.empty()) next = std::make_unique<Block>();
            else { next = std::move(spare_.back()); spare_.pop_back(); }
            next->reset();
            auto* raw = next.get();
            blocks_.push_back(std::move(next));
            writer_->next.store(raw, std::memory_order_release);
            writer_ = raw;
            writeIndex_ = 0;
        }
        writer_->values[writeIndex_] = command;
        writer_->published.store(++writeIndex_, std::memory_order_release);
    }

    // Audio only, with a finite budget in the realtime callback. apply must not
    // retain a reference to a slot or reenter this queue. No owning destructor
    // runs here. The queue does not make the command handler realtime-safe.
    template<class Apply>
    std::size_t consume(std::size_t budget, Apply&& apply) noexcept(noexcept(apply(std::declval<const T&>()))) {
        std::size_t consumed = 0;
        while (consumed < budget) {
            if (readIndex_ == BlockSize) {
                auto* next = reader_->next.load(std::memory_order_acquire);
                if (!next) break;
                reader_ = next;
                readIndex_ = 0;
                // No read of the old block is allowed after this publication.
                readerPosition_.store(reader_, std::memory_order_release);
            }
            if (readIndex_ == reader_->published.load(std::memory_order_acquire)) break;
            apply(static_cast<const T&>(reader_->values[readIndex_]));
            ++readIndex_;
            ++consumed;
        }
        return consumed;
    }

    // Control only. A stale reader position merely retains extra old blocks.
    // Retain a small warm pool; release overflow storage only on control.
    void collectRetired() {
        const auto* reader = readerPosition_.load(std::memory_order_acquire);
        while (blocks_.front().get() != reader) {
            auto retired = std::move(blocks_.front());
            blocks_.pop_front();
            if (spare_.size() < SpareBlocks) spare_.push_back(std::move(retired));
        }
    }

    // Both sides must be quiescent. Used when replacing a graph/session.
    void resetAfterStop() {
        while (blocks_.size() > 1) {
            auto retired = std::move(blocks_.back());
            blocks_.pop_back();
            if (spare_.size() < SpareBlocks) spare_.push_back(std::move(retired));
        }
        writer_ = reader_ = blocks_.front().get();
        writer_->reset();
        writeIndex_ = readIndex_ = 0;
        readerPosition_.store(reader_, std::memory_order_relaxed);
    }
    // Control-side diagnostics; not safe to read from another control producer.
    std::size_t retainedBlocks() const noexcept { return blocks_.size() + spare_.size(); }

private:
    std::deque<std::unique_ptr<Block>> blocks_;
    std::vector<std::unique_ptr<Block>> spare_;
    alignas(64) Block* writer_ = nullptr;
    std::size_t writeIndex_ = 0;
    alignas(64) Block* reader_ = nullptr;
    std::size_t readIndex_ = 0;
    alignas(64) std::atomic<Block*> readerPosition_{nullptr};
};
} // namespace catlive::audio
