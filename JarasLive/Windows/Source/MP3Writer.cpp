#include "MP3Writer.h"
#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <wrl/client.h>
namespace catlive {
using Microsoft::WRL::ComPtr;
namespace {
void checked(HRESULT result, const char *operation) {
    if (FAILED(result))
        throw std::runtime_error(std::string(operation) + " (0x" +
                                 utf8(String::toHexString((int)result)) + ")");
}
} // namespace
struct MP3Writer::Impl {
    bool com = false, mf = false, finished = false;
    int rate = 48000, channels = 2;
    DWORD stream = 0;
    int64 frames = 0;
    ComPtr<IMFSinkWriter> writer;
    ~Impl() {
        writer.Reset();
        if (mf)
            MFShutdown();
        if (com)
            CoUninitialize();
    }
};
MP3Writer::MP3Writer(const File &file, int rate, int channels, int bitrate)
    : impl(std::make_unique<Impl>()) {
    auto &p = *impl;
    p.rate = rate;
    p.channels = channels;
    const auto com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (com != RPC_E_CHANGED_MODE) {
        checked(com, "COM initialization");
        p.com = true;
    }
    checked(MFStartup(MF_VERSION), "Media Foundation initialization");
    p.mf = true;
    ComPtr<IMFCollection> types;
    checked(MFTranscodeGetAudioOutputAvailableTypes(MFAudioFormat_MP3, MFT_ENUM_FLAG_ALL, nullptr,
                                                    &types),
            "MP3 encoder availability");
    DWORD size = 0;
    checked(types->GetElementCount(&size), "MP3 formats");
    ComPtr<IMFMediaType> output;
    for (DWORD i = 0; i < size; ++i) {
        ComPtr<IUnknown> item;
        checked(types->GetElement(i, &item), "MP3 format");
        ComPtr<IMFMediaType> type;
        checked(item.As(&type), "MP3 media type");
        UINT32 r = 0, c = 0, b = 0;
        type->GetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, &r);
        type->GetUINT32(MF_MT_AUDIO_NUM_CHANNELS, &c);
        type->GetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, &b);
        if (r == (UINT32)rate && c == (UINT32)channels && b == (UINT32)(bitrate * 1000 / 8)) {
            output = type;
            break;
        }
    }
    if (!output)
        throw std::runtime_error(
            "A combinação de frequência, canais e bitrate MP3 não está disponível.");
    checked(MFCreateSinkWriterFromURL(file.getFullPathName().toWideCharPointer(), nullptr, nullptr,
                                      &p.writer),
            "Create MP3 output");
    checked(p.writer->AddStream(output.Get(), &p.stream), "MP3 output stream");
    ComPtr<IMFMediaType> input;
    checked(MFCreateMediaType(&input), "Create PCM type");
    checked(input->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio), "PCM major type");
    checked(input->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM), "PCM subtype");
    checked(input->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, (UINT32)channels), "PCM channels");
    checked(input->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, (UINT32)rate), "PCM rate");
    checked(input->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16), "PCM depth");
    checked(input->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, (UINT32)(channels * 2)), "PCM alignment");
    checked(input->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, (UINT32)(rate * channels * 2)),
            "PCM byte rate");
    checked(p.writer->SetInputMediaType(p.stream, input.Get(), nullptr), "MP3 input format");
    checked(p.writer->BeginWriting(), "Begin MP3 encoding");
}
MP3Writer::~MP3Writer() = default;
void MP3Writer::write(const AudioBuffer<float> &audio, int count) {
    auto &p = *impl;
    if (p.finished)
        throw std::runtime_error("MP3 writer already finalized.");
    const DWORD bytes = (DWORD)(count * p.channels * 2);
    ComPtr<IMFMediaBuffer> buffer;
    checked(MFCreateMemoryBuffer(bytes, &buffer), "MP3 sample buffer");
    BYTE *data = nullptr;
    checked(buffer->Lock(&data, nullptr, nullptr), "MP3 sample lock");
    auto *pcm = reinterpret_cast<int16 *>(data);
    for (int n = 0; n < count; ++n)
        for (int ch = 0; ch < p.channels; ++ch) {
            const float value = audio.getSample(ch, n);
            pcm[n * p.channels + ch] =
                (int16)jlimit(-32768, 32767, (int)std::lround(jlimit(-1.f, 1.f, value) * 32767.f));
        }
    checked(buffer->Unlock(), "MP3 sample unlock");
    checked(buffer->SetCurrentLength(bytes), "MP3 sample length");
    ComPtr<IMFSample> sample;
    checked(MFCreateSample(&sample), "MP3 sample");
    checked(sample->AddBuffer(buffer.Get()), "MP3 sample data");
    const auto start = p.frames * 10000000 / p.rate, end = (p.frames + count) * 10000000 / p.rate;
    checked(sample->SetSampleTime(start), "MP3 sample time");
    checked(sample->SetSampleDuration(end - start), "MP3 sample duration");
    checked(p.writer->WriteSample(p.stream, sample.Get()), "MP3 encoding");
    p.frames += count;
}
void MP3Writer::finish() {
    auto &p = *impl;
    if (!p.finished) {
        checked(p.writer->Finalize(), "Finalize MP3");
        p.finished = true;
        p.writer.Reset();
    }
}
} // namespace catlive
