#pragma once
#include "../../Core/MIDI/RealtimeMIDIQueue.hpp"
namespace catlive {
// Prepared destinations have 32768 bytes. At most 512 short events plus 48
// recovery controllers use < 6000 bytes; routing keyboard + hardware also fits.
class RealtimeMIDIInput {
public:
    void addMessageToQueue(const MidiMessage &message) noexcept {
        queue->push(message.getRawData(),size_t(message.getRawDataSize()),message.getTimeStamp());
    }
    // Called with the device stopped, before it starts consuming again.
    void reset(double sampleRate) noexcept {
        rate=sampleRate;lastTime=Time::getMillisecondCounterHiRes()*.001;queue->invalidate();
        queue->discardPending();
    }
    void removeNextBlockOfMessages(MidiBuffer &output,int samples) {
        if(samples<=0)return; // Keep queued events and recovery for an audible block.
        const double now=Time::getMillisecondCounterHiRes()*.001;
        const double span=std::max(1./rate,now-lastTime),block=samples/rate;
        const auto epoch=queue->epoch();
        if(epoch!=consumedEpoch) {
            // Losing a note-off must never leave a stuck note or sustain pedal.
            for(int channel=1;channel<=16;++channel) {
                output.addEvent(MidiMessage::controllerEvent(channel,64,0),0);
                // Keyboard routes still know the original target channels when
                // all-sound-off arrives; all-notes-off clears that held state.
                output.addEvent(MidiMessage::allSoundOff(channel),0);
                output.addEvent(MidiMessage::allNotesOff(channel),0);
            }
            consumedEpoch=epoch;
        }
        jaras::RealtimeMIDIQueue<>::Event event;
        unsigned emitted=0;
        // Stale events must not delay fresh notes by several audio blocks. The
        // scan remains bounded by storage, with at most 512 events emitted.
        for(std::size_t scanned=0;scanned<jaras::RealtimeMIDIQueue<>::capacity && emitted<512 && queue->pop(event);++scanned) {
            if(event.generation!=epoch)continue;
            const double elapsed=std::max(0.,event.seconds-lastTime);
            const double at=span>block?elapsed/span*samples:(block-span+elapsed)*rate;
            const int offset=std::isfinite(at)?jlimit(0,std::max(0,samples-1),int(std::clamp(at,0.,double(std::max(0,samples-1))))):0;
            output.addEvent(event.data.data(),event.size,offset);
            ++emitted;
        }
        lastTime=now;
    }
    uint64 droppedCount()const noexcept{return queue->droppedCount();}
    uint64 unsupportedCount()const noexcept{return queue->unsupportedCount();}
private:
    std::unique_ptr<jaras::RealtimeMIDIQueue<>> queue=std::make_unique<jaras::RealtimeMIDIQueue<>>();
    uint64 consumedEpoch=0;
    double rate=48000,lastTime=0;
};
}
