#pragma once

#include <atomic>
#include <cassert>
#include <deque>
#include <memory>
#include <type_traits>
#include <utility>

namespace catlive::audio {
// Control owns every edit, including the resources displaced by its callback.
// Publish the returned non-owning ticket in the same ordered command stream as
// transport/mixer commands. One serialized control producer and audio consumer.
// A ticket runs exactly once. Resource preparation/destruction never runs here
// on audio; the caller must supply a bounded, allocation-free noexcept operation.
class PreparedAudioEdits final {
public:
    struct Ticket {
        virtual ~Ticket() = default; // Control only.
    private:
        friend class PreparedAudioEdits;
        virtual void apply() noexcept = 0;
        enum Phase : unsigned { pending, running, cancelled, completed };
        std::atomic<unsigned> phase{pending};
    };
    static_assert(std::atomic<unsigned>::is_always_lock_free);

    template<class Work>
    Ticket* prepare(Work&& work) {
        using Function = std::decay_t<Work>;
        static_assert(std::is_nothrow_invocable_v<Function&>);
        struct Entry final : Ticket {
            explicit Entry(Function&& fn) : function(std::move(fn)) {}
            void apply() noexcept override { function(); }
            Function function;
        };
        collectRetired();
        auto entry = std::make_unique<Entry>(Function(std::forward<Work>(work)));
        auto* ticket = entry.get();
        entries_.push_back(std::move(entry));
        return ticket;
    }

    static void execute(Ticket* ticket) noexcept {
        unsigned expected=Ticket::pending;
        if(ticket->phase.compare_exchange_strong(expected,Ticket::running,std::memory_order_acq_rel))
            ticket->apply();
        else { assert(expected==Ticket::cancelled); }
        // Last access to ticket: control may immediately destroy it, including
        // the captured resources, after observing this release publication.
        ticket->phase.store(Ticket::completed, std::memory_order_release);
    }
    // Serialized control can abandon a command only before audio starts it.
    // A cancelled ticket stays owned until audio consumes its queue entry.
    static bool cancelPending(Ticket* ticket) noexcept {
        unsigned expected=Ticket::pending;
        return ticket->phase.compare_exchange_strong(expected,Ticket::cancelled,std::memory_order_acq_rel);
    }
    static bool isComplete(const Ticket* ticket) noexcept {
        return ticket->phase.load(std::memory_order_acquire)==Ticket::completed;
    }
    // Control only, if publication in the command stream failed. The newest
    // ticket must not have been made visible to the consumer.
    void cancelUnpublished(Ticket* ticket) noexcept {
        assert(!entries_.empty() && entries_.back().get() == ticket);
        entries_.pop_back();
    }
    void collectRetired() {
        while (!entries_.empty() && isComplete(entries_.front().get()))
            entries_.pop_front();
    }
    // First stop/exclude the consumer and discard every queued raw ticket.
    // Pending edits are cancelled, not applied. Destruction has the same rule.
    void resetAfterStop() noexcept { entries_.clear(); }
    std::size_t retained() const noexcept { return entries_.size(); } // Control only.

private:
    std::deque<std::unique_ptr<Ticket>> entries_;
};
} // namespace catlive::audio
