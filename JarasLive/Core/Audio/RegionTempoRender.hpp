#pragma once
#include "CatLiveStretch.hpp"
#include "../../WindowsNative/ThirdParty/dr_libs/dr_wav.h"
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <filesystem>
#include <stdexcept>
#include <vector>

namespace catlive::regionTempo {
// Each anchor is a measured second on the original timeline and its corresponding
// second at the fixed BPM, both relative to this item. First and last are inclusive.
struct Anchor { double source, output; };

template<class Progress>
void render(const std::filesystem::path& input, const std::filesystem::path& output,
            const std::vector<Anchor>& anchors, Progress progress) {
    if (anchors.size() < 2 || anchors.front().source != 0 || anchors.front().output != 0)
        throw std::invalid_argument("Invalid tempo map.");
    for (size_t i = 1; i < anchors.size(); ++i)
        if (!std::isfinite(anchors[i].source) || !std::isfinite(anchors[i].output) ||
            anchors[i].source <= anchors[i-1].source || anchors[i].output <= anchors[i-1].output)
            throw std::invalid_argument("Invalid tempo segment.");
    struct Wave {
        drwav file{}; bool open = false;
        ~Wave() { if (open) drwav_uninit(&file); }
    } src, dst;
#ifdef _WIN32
    src.open = drwav_init_file_w(&src.file, input.c_str(), nullptr);
#else
    src.open = drwav_init_file(&src.file, input.c_str(), nullptr);
#endif
    if (!src.open || !src.file.sampleRate || src.file.channels < 1 || src.file.channels > 2)
        throw std::runtime_error("Could not read the rendered audio.");
    const int channels = int(src.file.channels);
    const double sampleRate = src.file.sampleRate;
    const auto frames = std::llround(anchors.back().output * sampleRate);
    if (frames < 1 || std::abs(double(src.file.totalPCMFrameCount) - anchors.back().source * sampleRate) > 2)
        throw std::runtime_error("The rendered source has an unexpected duration.");
    const drwav_data_format format{frames * channels * 4LL > 0xfffff000LL ? drwav_container_rf64 : drwav_container_riff,
        DR_WAVE_FORMAT_IEEE_FLOAT, src.file.channels, src.file.sampleRate, 32};
    if (std::filesystem::exists(output)) throw std::runtime_error("The destination file already exists.");
#ifdef _WIN32
    dst.open = drwav_init_file_write_w(&dst.file, output.c_str(), &format, nullptr);
#else
    dst.open = drwav_init_file_write(&dst.file, output.c_str(), &format, nullptr);
#endif
    if (!dst.open) throw std::runtime_error("Could not create the adjusted WAV.");
    try {
        signalsmith::stretch::SignalsmithStretch<float> stretch{0};
        stretch.presetDefault(channels, float(sampleRate));
        const auto inputLead = stretch.inputLatency(), outputLead = stretch.outputLatency();
        size_t span = 1;
        auto sourceFrame = [&](long long outputFrame) {
            const auto time = double(outputFrame) / sampleRate;
            while (span + 1 < anchors.size() && anchors[span].output <= time) ++span;
            const auto &a = anchors[span-1], &b = anchors[span];
            return std::llround((a.source + (time-a.output)*(b.source-a.source)/(b.output-a.output))*sampleRate);
        };
        std::vector<float> interleaved, left, right, result(512*channels);
        std::array<float,512> outL{},outR{};
        float *outs[]{outL.data(),outR.data()};
        long long readFrame = 0;
        auto readTo = [&](long long next) {
            const int n = int(next-readFrame);
            if (n < 0) throw std::runtime_error("Invalid audio clock.");
            interleaved.assign(size_t(n)*channels,0);
            const auto available = std::max<long long>(0, static_cast<long long>(src.file.totalPCMFrameCount)-readFrame);
            const auto wanted = static_cast<drwav_uint64>(std::min<long long>(available,n));
            if (wanted && drwav_read_pcm_frames_f32(&src.file,wanted,interleaved.data()) != wanted)
                throw std::runtime_error("Could not read the complete source.");
            left.resize(n);right.resize(n);
            for (int i=0;i<n;++i) {
                left[i]=interleaved[i*channels];
                if(channels==2)right[i]=interleaved[i*2+1];
            }
            readFrame=next;
            return n;
        };
        // Prime using the actual future source at the synthesis latency. The
        // lookahead and absolute frame endpoints keep transients on the grid.
        const int prime=readTo(inputLead+sourceFrame(outputLead));
        const float *head[]{left.data(),right.data()};
        stretch.outputSeek(head,prime);
        for (long long at=0;at<frames;) {
            const int count=int(std::min<long long>(512,frames-at));
            const int n=readTo(inputLead+sourceFrame(at+count+outputLead));
            const float *ins[]{left.data(),right.data()};
            stretch.process(ins,n,outs,count);
            if(at>=0) {
                for(int i=0;i<count;++i) for(int c=0;c<channels;++c) result[i*channels+c]=outs[c][i];
                if(drwav_write_pcm_frames(&dst.file,count,result.data()) != static_cast<drwav_uint64>(count))
                    throw std::runtime_error("Could not write the complete adjusted WAV.");
            }
            at+=count;
            if(!progress(std::clamp(double(at)/frames,0.,1.))) throw std::runtime_error("Operation cancelled.");
        }
        const auto status=drwav_uninit(&dst.file);dst.open=false;
        if(status!=DRWAV_SUCCESS)throw std::runtime_error("Could not finish writing the adjusted WAV.");
    } catch (...) {
        if(dst.open){drwav_uninit(&dst.file);dst.open=false;}
        std::error_code ignored;std::filesystem::remove(output,ignored);throw;
    }
}
}
