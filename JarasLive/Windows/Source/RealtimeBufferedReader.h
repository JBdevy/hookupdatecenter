#pragma once
#include "Common.h"
namespace catlive {
// Decode on the existing read-ahead worker. Audio only leases immutable pages:
// no mutex, file I/O, allocation, deletion, notification or waiting at timeout 0.
class RealtimeBufferedReader final : public AudioFormatReader, private TimeSliceClient {
public:
    RealtimeBufferedReader(AudioFormatReader *reader,TimeSliceThread &worker,int capacity)
        : AudioFormatReader(nullptr,reader->getFormatName()),source(reader),thread(worker),
          pageCount(std::max(4,(capacity+pageFrames-1)/pageFrames+3)),pages(std::make_unique<Page[]>(size_t(pageCount))) {
        sampleRate=source->sampleRate;lengthInSamples=source->lengthInSamples;
        numChannels=source->numChannels;bitsPerSample=32;usesFloatingPointData=true;
        for(int i=0;i<pageCount;++i)pages[size_t(i)].pcm.setSize(int(numChannels),pageFrames);
        thread.addTimeSliceClient(this);
    }
    ~RealtimeBufferedReader()override {thread.removeTimeSliceClient(this);}
    void setReadTimeout(int milliseconds)noexcept{timeout.store(std::max(0,milliseconds),std::memory_order_relaxed);}
    bool readSamples(int *const *output,int channels,int offset,int64 at,int count)override {
        requested.store(std::max<int64>(0,at),std::memory_order_relaxed);
        const int wait=timeout.load(std::memory_order_relaxed);
        if(wait==0) {
            const auto result=copyPages(output,channels,offset,at,count);
            return result.complete && result.decoded;
        }
        // Only offline export opts into waiting. Live and preparation probes use 0.
        const auto began=Time::getMillisecondCounter();
        do {
            const auto result=copyPages(output,channels,offset,at,count);
            if(result.complete)return result.decoded;
            if(uint32(Time::getMillisecondCounter()-began)>=uint32(wait))return false;
            Thread::sleep(1);
        }while(true);
    }
private:
    static constexpr int pageFrames=16384;
    // One writer bit and 31 reader-count bits. A rejected lease still owns its
    // count until release, including when decoding finishes in the meantime.
    static constexpr uint32 writing=uint32(1)<<31;
    static_assert(std::atomic<uint32>::is_always_lock_free && std::atomic<int64>::is_always_lock_free);
    struct Page {
        std::atomic<uint32> readers{0};
        std::atomic<int64> first{-1};
        AudioBuffer<float> pcm;
        bool decoded=false; // read/written only while the page is leased
    };
    std::unique_ptr<AudioFormatReader> source;
    TimeSliceThread &thread;
    const int pageCount;
    std::unique_ptr<Page[]> pages;
    std::atomic<int64> requested{0};
    std::atomic<int> timeout{0};
    struct CopyResult { bool complete=true,decoded=true; };
    CopyResult copyPages(int *const *output,int channels,int offset,int64 at,int count)noexcept {
        CopyResult result;
        for(int done=0;done<count;) {
            const auto position=at+done;
            const int chunk=position<0?int(std::min<int64>(count-done,-position)):
                position>=lengthInSamples?count-done:std::min(count-done,pageFrames-int(position%pageFrames));
            bool copied=position<0||position>=lengthInSamples;
            if(!copied) {
                auto &page=pages[size_t((position/pageFrames)%pageCount)];
                const auto readers=page.readers.fetch_add(1,std::memory_order_acquire);
                if((readers&writing)==0) {
                    const auto first=page.first.load(std::memory_order_relaxed);
                    if(first>=0 && position>=first && position-first+chunk<=pageFrames) {
                        for(int ch=0;output && ch<channels;++ch)if(output[ch]) {
                            auto *destination=reinterpret_cast<float*>(output[ch])+offset+done;
                            if(ch<page.pcm.getNumChannels())FloatVectorOperations::copy(destination,page.pcm.getReadPointer(ch,int(position-first)),chunk);
                            else FloatVectorOperations::clear(destination,chunk);
                        }
                        copied=true;result.decoded &= page.decoded;
                    }
                }
                page.readers.fetch_sub(1,std::memory_order_release);
            }
            if(!copied || position<0 || position>=lengthInSamples)
                for(int ch=0;output && ch<channels;++ch)if(output[ch])FloatVectorOperations::clear(reinterpret_cast<float*>(output[ch])+offset+done,chunk);
            result.complete &= copied;done+=chunk;
        }
        return result;
    }
    int useTimeSlice()override {
        const auto at=requested.load(std::memory_order_relaxed);
        const auto base=at/pageFrames*pageFrames;
        // Prioritize the exact requested page, then its forward read-ahead.
        // Use every slot: one backward page and the remaining forward pages.
        // The extra forward page covers unaligned reads plus interpolation tails.
        for(int distance=0;distance<pageCount;++distance) {
            const auto wanted=distance==pageCount-1?base-pageFrames:base+int64(distance)*pageFrames;
            if(wanted<0 || wanted>=lengthInSamples)continue;
            auto &page=pages[size_t((wanted/pageFrames)%pageCount)];
            if(page.first.load(std::memory_order_acquire)==wanted)continue;
            uint32 empty=0;
            if(!page.readers.compare_exchange_strong(empty,writing,std::memory_order_acquire))return 1;
            page.first.store(-1,std::memory_order_release);
            page.pcm.clear();
            try {
                page.decoded=source->read(page.pcm.getArrayOfWritePointers(),int(numChannels),wanted,pageFrames);
                // JUCE skips fixed-to-float conversion on failure. Such bytes
                // cannot be published as usable partial floating-point PCM.
                if(!page.decoded && !source->usesFloatingPointData)page.pcm.clear();
            }
            catch(...) {page.decoded=false;page.pcm.clear();}
            page.first.store(wanted,std::memory_order_release);
            // Preserve readers which observed the writer bit and are still
            // releasing their rejected leases; storing zero loses those counts.
            page.readers.fetch_sub(writing,std::memory_order_release);
            return 0;
        }
        return 2;
    }
};
}
