#import "../../../Apple/Bridge/JarasVST3.mm"
#include <cassert>
#include <cmath>

int main(int argc,char **argv){@autoreleasepool{
    assert(argc==3);
    NSDictionary *spec=@{@"id":@"mono",@"classID":@"1234123456785678ABCDEF0012345678",@"path":@(argv[1])};
    Instance plugin(spec,48000,false);
    assert(plugin.inputs[0].numChannels==1&&plugin.outputs[0].numChannels==1);
    constexpr unsigned frames=128;
    float left[frames],right[frames];
    struct Stereo{UInt32 count;AudioBuffer channels[2];} buffers{2,{{1,sizeof(left),left},{1,sizeof(right),right}}};
    for(const auto &values:std::vector<std::array<float,2>>{{.2f,.6f},{0,.6f},{.2f,0},{.2f,-.2f},{0,0}}){
        std::fill_n(left,frames,values[0]);std::fill_n(right,frames,values[1]);
        plugin.process((AudioBufferList *)&buffers,frames,0,120,4,4,true,nullptr,0);
        const float expected=(values[0]+values[1])*.25f; // Mono fold-down and fixture gain 0.5.
        for(unsigned i=0;i<frames;++i){assert(std::abs(left[i]-expected)<1e-6);assert(std::abs(right[i]-expected)<1e-6);}
    }
    NSMutableDictionary *surround=[spec mutableCopy];surround[@"path"]=@(argv[2]);
    bool rejected=false;
    try{Instance unsupported(surround,48000,false);}catch(const std::exception &e){rejected=std::string(e.what()).find("channel layout")!=std::string::npos;}
    assert(rejected);
    puts("VST3_MONO_FOLD_DOWN_OUTPUT_DUPLICATION_SILENCE_AND_SURROUND_REJECTION_OK");
}}
