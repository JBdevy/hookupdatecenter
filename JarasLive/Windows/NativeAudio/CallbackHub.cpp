#include "CallbackHub.h"
#include <algorithm>
#include <cmath>
#include <exception>
#include <limits>
#include <stdexcept>
#include <utility>

namespace catlive::native::audio {
static_assert(std::atomic<void*>::is_always_lock_free);
static_assert(std::atomic<std::uint64_t>::is_always_lock_free);

struct CallbackHub::Snapshot {
    std::uint64_t generation = 0;
    std::vector<Client> clients;
};

namespace {
void validateMap(const std::vector<std::uint32_t>& map, std::uint32_t channels)
{
    if (channels > CallbackHub::maximumChannels || map.size() > channels)
        throw std::invalid_argument("Native callback hub channel count exceeds prepared limits");
    std::array<bool, CallbackHub::maximumChannels> seen {};
    for (auto index : map) {
        if (index >= channels || seen[index])
            throw std::invalid_argument("Native callback hub requires unique valid physical channel indices");
        seen[index] = true;
    }
}
}

CallbackHub::CallbackHub(Configuration configuration)
    : configuration_(std::move(configuration)), controlThread_(std::this_thread::get_id())
{
    if (!std::isfinite(configuration_.sampleRate) || configuration_.sampleRate <= 0
        || configuration_.maximumBlockFrames == 0
        || configuration_.maximumBlockFrames > maximumFrames)
        throw std::invalid_argument("Native callback hub requires a valid prepared sample rate and frame capacity");
    validateMap(configuration_.inputPhysicalIndices, configuration_.physicalInputChannels);
    validateMap(configuration_.outputPhysicalIndices, configuration_.physicalOutputChannels);
    silence_.resize(configuration_.maximumBlockFrames, 0.0f);
    inputScratch_.resize(configuration_.inputPhysicalIndices.size()
                             * configuration_.maximumBlockFrames, 0.0f);
    scratch_.resize(static_cast<std::size_t>(configuration_.physicalOutputChannels)
                        * configuration_.maximumBlockFrames, 0.0f);
    for (std::uint32_t channel = 0; channel < configuration_.physicalOutputChannels; ++channel)
        physicalOutputs_[channel] = scratch_.data()
            + static_cast<std::size_t>(channel) * configuration_.maximumBlockFrames;
}

CallbackHub::~CallbackHub()
{
    // A concurrent destructor would otherwise free callback-owned storage.
    // This diagnoses misuse; it is not a substitute for joining the device.
    if (std::this_thread::get_id() != controlThread_ || rendering_.test(std::memory_order_acquire))
        std::terminate();
    delete pending_.exchange(nullptr, std::memory_order_acq_rel);
    collectRetiredUnchecked();
    delete current_;
}

void CallbackHub::requireControlThread() const
{
    if (std::this_thread::get_id() != controlThread_)
        throw std::logic_error("Native callback hub control methods require their construction thread");
}

std::uint64_t CallbackHub::publish(std::span<const Client> clients)
{
    requireControlThread();
    if (clients.size() > maximumClients)
        throw std::invalid_argument("Native callback hub client capacity exceeded");
    for (std::size_t i = 0; i < clients.size(); ++i) {
        if (clients[i].id == 0 || !clients[i].render)
            throw std::invalid_argument("Native callback hub client requires an ID and callback");
        for (std::size_t j = 0; j < i; ++j)
            if (clients[i].id == clients[j].id)
                throw std::invalid_argument("Native callback hub client IDs must be unique");
    }
    if (nextGeneration_ == std::numeric_limits<std::uint64_t>::max())
        throw std::overflow_error("Native callback hub generation exhausted");
    auto next = std::make_unique<Snapshot>();
    next->generation = nextGeneration_++;
    next->clients.assign(clients.begin(), clients.end());
    const auto generation = next->generation;
    delete pending_.exchange(next.release(), std::memory_order_acq_rel);
    collectRetiredUnchecked();
    return generation;
}

void CallbackHub::collectRetiredUnchecked() noexcept
{
    delete retired_.exchange(nullptr, std::memory_order_acq_rel);
}

bool CallbackHub::collectRetired()
{
    requireControlThread();
    auto* previous = retired_.exchange(nullptr, std::memory_order_acq_rel);
    const bool collected = previous != nullptr;
    delete previous;
    return collected;
}

void CallbackHub::resetAfterStop()
{
    requireControlThread();
    if (rendering_.test(std::memory_order_acquire))
        throw std::logic_error("Native callback hub reset requires a stopped and joined device");
    delete pending_.exchange(nullptr, std::memory_order_acq_rel);
    collectRetiredUnchecked();
    delete std::exchange(current_, nullptr);
    adoptedGeneration_.store(0, std::memory_order_relaxed);
}

void CallbackHub::adoptPending() noexcept
{
    if (retired_.load(std::memory_order_acquire) != nullptr)
        return;
    if (auto* next = pending_.exchange(nullptr, std::memory_order_acq_rel)) {
        auto* previous = std::exchange(current_, next);
        adoptedGeneration_.store(next->generation, std::memory_order_relaxed);
        if (previous)
            retired_.store(previous, std::memory_order_release);
    }
}

bool CallbackHub::validBlock(const AudioBlock& block) const noexcept
{
    return block.frames <= configuration_.maximumBlockFrames
        && block.inputChannels == configuration_.inputPhysicalIndices.size()
        && block.outputChannels == configuration_.outputPhysicalIndices.size()
        && block.sampleRate == configuration_.sampleRate
        && (block.outputChannels == 0 || block.outputs != nullptr);
}

void CallbackHub::process(void* user, const AudioBlock& block) noexcept
{
    if (user)
        static_cast<CallbackHub*>(user)->render(block);
}

void CallbackHub::render(const AudioBlock& block) noexcept
{
    if (rendering_.test_and_set(std::memory_order_acquire)) {
        overlappingCallbacks_.fetch_add(1, std::memory_order_relaxed);
        return; // Device contract already cleared this callback's outputs.
    }
    struct RenderLease {
        std::atomic_flag& flag;
        ~RenderLease() { flag.clear(std::memory_order_release); }
    } lease { rendering_ };
    if (!validBlock(block)) {
        invalidBlocks_.fetch_add(1, std::memory_order_relaxed);
        return; // No access beyond prepared capacity, including on failure.
    }
    if (block.frames == 0)
        return; // Do not advance the publication or transport on empty blocks.
    adoptPending();
    for (std::uint32_t channel = 0; channel < configuration_.physicalInputChannels; ++channel)
        physicalInputs_[channel] = silence_.data();
    if (block.inputs)
        for (std::size_t packed = 0; packed < configuration_.inputPhysicalIndices.size(); ++packed)
            if (block.inputs[packed]) {
                // Copy before clearing outputs, also supporting an adapter
                // whose capture and render planes alias the same storage.
                auto* input = inputScratch_.data() + packed * configuration_.maximumBlockFrames;
                std::copy_n(block.inputs[packed], block.frames, input);
                physicalInputs_[configuration_.inputPhysicalIndices[packed]] = input;
            }
    for (std::uint32_t channel = 0; channel < block.outputChannels; ++channel)
        if (block.outputs[channel])
            std::fill_n(block.outputs[channel], block.frames, 0.0f);

    AudioBlock clientBlock = block;
    clientBlock.inputChannels = configuration_.physicalInputChannels;
    clientBlock.outputChannels = configuration_.physicalOutputChannels;
    clientBlock.inputs = clientBlock.inputChannels ? physicalInputs_.data() : nullptr;
    clientBlock.outputs = clientBlock.outputChannels ? physicalOutputs_.data() : nullptr;
    std::uint64_t calls = 0;
    if (current_)
        for (const auto& client : current_->clients) {
            for (std::uint32_t channel = 0; channel < clientBlock.outputChannels; ++channel)
                std::fill_n(physicalOutputs_[channel], block.frames, 0.0f);
            client.render(client.context, clientBlock);
            ++calls;
            for (std::size_t packed = 0; packed < configuration_.outputPhysicalIndices.size(); ++packed) {
                auto* output = block.outputs[packed];
                if (!output)
                    continue;
                const auto* scratch = physicalOutputs_[configuration_.outputPhysicalIndices[packed]];
                for (std::uint32_t frame = 0; frame < block.frames; ++frame)
                    output[frame] += scratch[frame];
            }
        }
    blocks_.fetch_add(1, std::memory_order_relaxed);
    frames_.fetch_add(block.frames, std::memory_order_relaxed);
    clientCalls_.fetch_add(calls, std::memory_order_relaxed);
}

CallbackHub::Statistics CallbackHub::statistics() const noexcept
{
    return { blocks_.load(std::memory_order_relaxed), frames_.load(std::memory_order_relaxed),
        clientCalls_.load(std::memory_order_relaxed), invalidBlocks_.load(std::memory_order_relaxed),
        overlappingCallbacks_.load(std::memory_order_relaxed), adoptedGeneration_.load(std::memory_order_relaxed) };
}
} // namespace catlive::native::audio
