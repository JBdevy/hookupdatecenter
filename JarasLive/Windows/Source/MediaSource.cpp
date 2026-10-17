#include "MediaSource.h"
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <wrl/client.h>
namespace catlive {
namespace {
using Microsoft::WRL::ComPtr;
struct Apartment {
    HRESULT result=CoInitializeEx(nullptr,COINIT_MULTITHREADED);
    ~Apartment(){if(SUCCEEDED(result))CoUninitialize();}
};
void check(HRESULT result) {if(FAILED(result))throw std::runtime_error("Não foi possível ler esta mídia (Windows " + std::to_string((unsigned long)result) + ").");}
ComPtr<IMFSourceReader> openSource(const File &file) {
    static const HRESULT startup=MFStartup(MF_VERSION);
    check(startup);ComPtr<IMFSourceReader> reader;
    check(MFCreateSourceReaderFromURL(file.getFullPathName().toWideCharPointer(),nullptr,&reader));return reader;
}
double duration(IMFSourceReader *reader) {
    PROPVARIANT value;PropVariantInit(&value);
    check(reader->GetPresentationAttribute(MF_SOURCE_READER_MEDIASOURCE,MF_PD_DURATION,&value));
    double result=value.vt==VT_UI8?double(value.uhVal.QuadPart)/1e7:value.vt==VT_I8?double(value.hVal.QuadPart)/1e7:0;
    PropVariantClear(&value);return result;
}
bool hasStream(IMFSourceReader *reader,DWORD stream) {ComPtr<IMFMediaType> type;return SUCCEEDED(reader->GetNativeMediaType(stream,0,&type));}
// MF seeks to a preceding sample/keyframe. Timestamp alignment below discards
// the leading samples instead of moving a video's audio relative to the grid.
class MediaReader final : public AudioFormatReader {
    ComPtr<IMFSourceReader> reader;
    std::vector<float> block;
    int64 blockStart=0,next=-1;
    bool ended=false;
  public:
    explicit MediaReader(const File &file):AudioFormatReader(nullptr,"Windows media") {
        Apartment apartment;reader=openSource(file);
        check(reader->SetStreamSelection(MF_SOURCE_READER_ALL_STREAMS,FALSE));
        check(reader->SetStreamSelection(MF_SOURCE_READER_FIRST_AUDIO_STREAM,TRUE));
        ComPtr<IMFMediaType> format;check(MFCreateMediaType(&format));
        check(format->SetGUID(MF_MT_MAJOR_TYPE,MFMediaType_Audio));check(format->SetGUID(MF_MT_SUBTYPE,MFAudioFormat_Float));
        check(reader->SetCurrentMediaType(MF_SOURCE_READER_FIRST_AUDIO_STREAM,nullptr,format.Get()));
        format.Reset();check(reader->GetCurrentMediaType(MF_SOURCE_READER_FIRST_AUDIO_STREAM,&format));
        UINT32 rate=0,channels=0;check(format->GetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND,&rate));check(format->GetUINT32(MF_MT_AUDIO_NUM_CHANNELS,&channels));
        if(!rate||!channels||channels>128)throw std::runtime_error("Formato de áudio da mídia inválido.");
        sampleRate=rate;numChannels=channels;bitsPerSample=32;usesFloatingPointData=true;
        lengthInSamples=(int64)std::llround(duration(reader.Get())*sampleRate);
    }
    bool readSamples(int *const *dest,int channels,int offset,int64 start,int count) override {
        Apartment apartment;
        for(int ch=0;ch<channels;++ch)if(dest[ch])FloatVectorOperations::clear(reinterpret_cast<float*>(dest[ch])+offset,count);
        try {
            if(start!=next){PROPVARIANT at;PropVariantInit(&at);at.vt=VT_I8;at.hVal.QuadPart=(LONGLONG)std::llround(start/sampleRate*1e7);check(reader->SetCurrentPosition(GUID_NULL,at));block.clear();ended=false;}
            int copied=0,emptySamples=0;
            while(copied<count) {
                const int64 position=start+copied,blockEnd=blockStart+(int64)(block.size()/numChannels);
                if(!block.empty() && position>=blockStart && position<blockEnd) {
                    const int n=(int)std::min<int64>(count-copied,blockEnd-position);
                    for(int ch=0;ch<std::min(channels,(int)numChannels);++ch)if(dest[ch]) {
                        auto *out=reinterpret_cast<float*>(dest[ch])+offset+copied;
                        for(int i=0;i<n;++i)out[i]=block[(size_t)(position-blockStart+i)*numChannels+(size_t)ch];
                    }
                    copied+=n;continue;
                }
                if(!block.empty() && position<blockStart) {copied+=(int)std::min<int64>(count-copied,blockStart-position);continue;}
                block.clear();if(ended)break;
                DWORD flags=0;LONGLONG stamp=0;ComPtr<IMFSample> sample;
                check(reader->ReadSample(MF_SOURCE_READER_FIRST_AUDIO_STREAM,0,nullptr,&flags,&stamp,&sample));
                ended=(flags&MF_SOURCE_READERF_ENDOFSTREAM)!=0;
                if(!sample){if(++emptySamples>1000)throw std::runtime_error("Mídia sem amostras de áudio.");continue;}
                emptySamples=0;ComPtr<IMFMediaBuffer> buffer;check(sample->ConvertToContiguousBuffer(&buffer));
                BYTE *bytes=nullptr;DWORD size=0;check(buffer->Lock(&bytes,nullptr,&size));
                block.resize(size/sizeof(float));std::memcpy(block.data(),bytes,block.size()*sizeof(float));buffer->Unlock();
                blockStart=(int64)std::llround(stamp*sampleRate/1e7);
            }
            next=start+count;return true;
        } catch(...) {next=-1;return false;}
    }
};
class MediaFormat final : public AudioFormat {
  public:
    MediaFormat():AudioFormat("Windows media",StringArray{".mp4",".mov",".m4v",".avi",".mkv",".webm",".wmv",".m4a",".aac"}){}
    Array<int> getPossibleSampleRates()override{return {};}
    Array<int> getPossibleBitDepths()override{return {32};}
    bool canDoStereo()override{return true;}bool canDoMono()override{return true;}bool isCompressed()override{return true;}
    AudioFormatReader *createReaderFor(InputStream *stream,bool deleteOnFailure)override {
        if(auto *file=dynamic_cast<FileInputStream*>(stream))try {auto reader=std::make_unique<MediaReader>(file->getFile());reader->input=stream;return reader.release();}catch(...){}
        if(deleteOnFailure)delete stream;return nullptr;
    }
    std::unique_ptr<AudioFormatWriter> createWriterFor(std::unique_ptr<OutputStream>&,const AudioFormatWriterOptions&)override{return {};}
};
}
MediaSourceInfo inspectMediaSource(const File &file) {Apartment apartment;auto reader=openSource(file);return {duration(reader.Get()),hasStream(reader.Get(),MF_SOURCE_READER_FIRST_AUDIO_STREAM),hasStream(reader.Get(),MF_SOURCE_READER_FIRST_VIDEO_STREAM)};}
void registerMediaSourceFormat(AudioFormatManager &formats){formats.registerFormat(new MediaFormat(),false);}
}
