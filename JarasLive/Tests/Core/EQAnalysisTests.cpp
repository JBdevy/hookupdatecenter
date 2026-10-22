#include "Include/EQAnalysis.hpp"
#include <cassert>
#include <chrono>
#include <cstdlib>
#include <iostream>
#include <memory>
#include <new>
#include <thread>
#include <vector>
using namespace catlive::analysis;
static std::atomic<unsigned long long> allocations{0};
void *operator new(std::size_t size) { allocations.fetch_add(1); if (auto *p=std::malloc(size)) return p; throw std::bad_alloc(); }
void operator delete(void *p) noexcept { std::free(p); }
void operator delete(void *p,std::size_t) noexcept { std::free(p); }

int main() {
    constexpr double pi = 3.14159265358979323846;
    for (double rate : {44100.,48000.}) {
        Capture capture(rate); Frame frame;
        std::array<float,4096> input{},output{},right{};
        for (std::size_t n=0;n<input.size();++n) {
            input[n]=float(std::sin(2*pi*1000*double(n)/rate));right[n]=-input[n];output[n]=input[n]*.5f;
        }
        assert(!capture.begin(input.data(),right.data(),int(input.size())));
        assert(!capture.read(frame)); capture.addReader();
        const auto allocated=allocations.load();
        assert(capture.begin(input.data(),right.data(),int(input.size())));
        capture.finish(output.data(),output.data()); assert(capture.read(frame));
        assert(allocations.load()==allocated);
        for(std::size_t n=0;n<sampleCount;++n) {
            assert(frame.input[0][n]==input[n+sampleCount]);
            assert(frame.input[1][n]==right[n+sampleCount]);
            assert(frame.output[0][n]==output[n+sampleCount]);
        }
        Analyzer analyzer; const auto before=allocations.load();
        auto spectrum=analyzer.analyze(&frame,1);
        assert(allocations.load()==before);
        const auto peak=std::size_t(std::max_element(spectrum.input.begin(),spectrum.input.end())-spectrum.input.begin());
        assert(std::abs(Spectrum::frequency(peak)-1000)<60);
        assert(spectrum.input[peak]>-30); // Opposite phase stereo must not cancel.
        assert(std::abs(spectrum.output[peak]-spectrum.input[peak]+6.0206f)<.05f);
        const auto initial=spectrum.input[peak];
        spectrum=analyzer.analyze(nullptr,0,.1);
        assert(spectrum.input[peak]<initial-6 && spectrum.input[peak]>initial-8);
        for(int n=0;n<100;++n)spectrum=analyzer.analyze(nullptr,0,.1);
        assert(spectrum.input[peak]==minimumDB);
        capture.removeReader(); const auto serial=capture.serial();
        assert(!capture.begin(input.data(),right.data(),256)); assert(capture.serial()==serial);
        // Different callback sizes retain one coherent, chronological pre/post window.
        capture.addReader(); std::uint64_t offset=0;
        for(int length : {17,64,511,128,2048,4096,73}) {
            for(int i=0;i<length;++i){input[std::size_t(i)]=float(offset+std::uint64_t(i));output[std::size_t(i)]=-input[std::size_t(i)];}
            assert(capture.begin(input.data(),nullptr,length));capture.finish(output.data(),nullptr);offset+=std::uint64_t(length);
            assert(capture.read(frame));
            const auto available=std::min(offset,std::uint64_t(sampleCount));
            for(std::size_t i=sampleCount-std::size_t(available);i<sampleCount;++i){
                assert(frame.input[0][i]==float(offset-sampleCount+i));assert(frame.input[1][i]==frame.input[0][i]);
                assert(frame.output[0][i]==-frame.input[0][i]);
            }
        }
        std::cout<<"EQ_RTA_STEREO_PRE_POST_GAIN_VARIABLE_BLOCKS_NO_ALLOCATION_OK rate="<<rate<<'\n';
    }
    // Concurrent publication can reject a busy snapshot, but may never return a
    // mixed input/output block. Atomic PCM also keeps rejected reads race-free.
    auto capture=std::make_unique<Capture>(48000);capture->addReader();
    std::atomic<bool> done{false};
    std::thread writer([&]{std::array<float,128> in{},out{};for(int block=1;block<=3000;++block){in.fill(float(block));out.fill(float(-block));assert(capture->begin(in.data(),nullptr,128));capture->finish(out.data(),nullptr);}done=true;});
    Frame frame;unsigned reads=0;
    do { if(capture->read(frame)){++reads;for(std::size_t i=0;i<sampleCount;++i){assert(frame.input[0][i]==frame.input[1][i]);assert(frame.output[0][i]==-frame.input[0][i]);}} }while(!done);
    writer.join();assert(capture->read(frame));assert(reads>0);
    Analyzer analyzer;const auto start=std::chrono::steady_clock::now();
    for(int n=0;n<200;++n)analyzer.analyze(&frame,1);
    std::cout<<"EQ_RTA_CONCURRENT_SNAPSHOT_OK FFT_ms="<<std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count()/200<<'\n';
}
