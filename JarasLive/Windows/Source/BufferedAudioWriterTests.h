#pragma once
#include "BufferedAudioWriter.h"

namespace catlive::bufferedAudioWriterTests {
struct Result {
    std::vector<float> samples;
    bool fail = false, destroyed = false;
};
class Sink final : public AudioFormatWriter {
public:
    explicit Sink(Result& result) : AudioFormatWriter(nullptr,"Test sink",48000,2,32), result(result) {
        usesFloatingPointData=true;
    }
    ~Sink() override { result.destroyed=true; }
    bool write(const int** input,int count) override {
        if(result.fail)return false;
        for(int i=0;i<count;++i)for(int channel=0;channel<2;++channel)
            result.samples.push_back(reinterpret_cast<const float*>(input[channel])[i]);
        return true;
    }
private:
    Result& result;
};
template<class Register> void run(Register&& test) {
    test("Recording preserves channel bounds and frame clock after device input changes",[] {
        auto require=[](bool ok,const char* message){if(!ok)throw std::runtime_error(message);};
        TimeSliceThread disk("Test changing device inputs");
        Result result;
        BufferedAudioWriter writer(std::make_unique<Sink>(result),disk,16);
        const float mono[]{.1f,.2f,.3f,.4f};
        const float* oneChannel[]{mono};
        require(writer.writeDeviceInput(oneChannel,1,4),"One-channel callback was rejected");
        // A null pointer is legal when the device reports no active inputs.
        require(writer.writeDeviceInput(nullptr,0,4),"Zero-input block did not preserve the take clock");
        const float right[]{-.1f,-.2f,-.3f,-.4f};const float* stereo[]{mono,right};
        require(writer.writeDeviceInput(stereo,2,4),"Restored stereo callback was rejected");
        require(result.samples.empty(),"Device callback wrote PCM to disk synchronously");
        writer.finish();
        require(!writer.failed()&&result.samples.size()==24,"Channel change lost recorded frame positions");
        for(int i=0;i<4;++i) {
            require(result.samples[2*i]==mono[i]&&result.samples[2*i+1]==0,"Absent right input was not silent");
            require(result.samples[8+2*i]==0&&result.samples[9+2*i]==0,"No-input block was not silent");
            require(result.samples[16+2*i]==mono[i]&&result.samples[17+2*i]==right[i],"Stereo did not resume at the expected frame");
        }
    });
    test("Recording PCM queue drains before finalization and reports disk failure",[] {
        auto require=[](bool ok,const char* message){if(!ok)throw std::runtime_error(message);};
        // Intentionally no running disk thread: the producer must neither wait
        // for a worker nor write synchronously, and Stop must flush queued PCM.
        TimeSliceThread disk("Test stalled recording disk");
        Result result;
        BufferedAudioWriter writer(std::make_unique<Sink>(result),disk,16);
        float left[16],right[16];
        for(int i=0;i<16;++i){left[i]=float(i)*.01f;right[i]=-left[i];}
        const float* planes[]{left,right};
        require(writer.write(planes,16),"Prepared recording queue rejected capacity");
        require(!writer.write(planes,1),"Full recording queue did not reject excess PCM");
        require(result.samples.empty(),"Device producer performed synchronous disk work");
        writer.finish();
        require(result.destroyed && !writer.failed(),"Writer was not finalized before return");
        require(result.samples.size()==32,"Stop lost or duplicated queued recording frames");
        for(int i=0;i<16;++i)
            require(result.samples[2*i]==left[i] && result.samples[2*i+1]==right[i],"Recording channel order or PCM changed");
        writer.finish();
        require(result.samples.size()==32,"Repeated finalization duplicated PCM");
        require(!writer.write(planes,1),"Finalized writer accepted another block");
        Result failure;failure.fail=true;
        BufferedAudioWriter broken(std::make_unique<Sink>(failure),disk,16);
        require(broken.write(planes,16),"Failed sink fixture did not queue PCM");
        broken.finish();
        require(broken.failed() && failure.destroyed,"Disk write failure was hidden");
    });
}
} // namespace catlive::bufferedAudioWriterTests
