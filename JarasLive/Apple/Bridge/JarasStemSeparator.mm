#import "JarasStemSeparator.h"
#if TARGET_OS_OSX
#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstring>
#include <fcntl.h>
#include <memory>
#include <mutex>
#include <poll.h>
#include <signal.h>
#include <string>
#include <thread>
#include <unistd.h>
#include <vector>

namespace CatStemRealtime {
// Three hops cover right context, GPU scheduling jitter and host render bursts.
// Keep this advertised delay fixed so track compensation remains stable.
constexpr unsigned modelRate=44100,hop=8192,rightContext=3072,modelDelay=24576,maxBlock=8192;
constexpr unsigned channels=2,stems=5,ringSlots=16;
static_assert(std::atomic<uint64_t>::is_always_lock_free && std::atomic<float>::is_always_lock_free);
enum Fault:int {none=0,inputOverrun=1,outputUnderrun=2,protocolFailure=3,backendFailure=4,offlineTimeout=5};
enum Type:uint16_t {ready=1,audio=2,output=3,flush=4,flushed=5,error=6,close=7,closed=8};
#pragma pack(push,1)
struct Header {
    char magic[4]={'C','S','T','1'};
    uint16_t version=1,type=0;
    uint64_t stream=1,generation=0,sequence=0;
    int64_t firstFrame=0;
    uint32_t sampleRate=modelRate,frames=0;
    uint16_t channels=2,stems=0;
    uint32_t payloadBytes=0,flags=0,reserved=0;
};
#pragma pack(pop)
static_assert(sizeof(Header)==64);
template<unsigned channelCount> struct Packet {
    uint64_t generation=0;
    int64_t firstFrame=0;
    uint32_t frames=0,rate=0;
    std::array<float,maxBlock*channelCount> samples{};
};
// Each cursor has exactly one writer. Epoch changes discard packets, never reset
// the opposite thread's cursor or mutate a published slot.
template<class T,unsigned capacity=ringSlots> struct Ring {
    std::array<T,capacity> slots;
    alignas(64) std::atomic<uint64_t> read{0};
    alignas(64) std::atomic<uint64_t> write{0};
    T *producerSlot(){const auto w=write.load(std::memory_order_relaxed);return w-read.load(std::memory_order_acquire)<capacity?&slots[w%capacity]:nullptr;}
    void publish(){write.fetch_add(1,std::memory_order_release);}
    T *consumerSlot(){const auto r=read.load(std::memory_order_relaxed);return r<write.load(std::memory_order_acquire)?&slots[r%capacity]:nullptr;}
    void consume(){read.fetch_add(1,std::memory_order_release);}
};

// Streaming, zero-phase 64-tap low-pass interpolation. The 32 input frames of
// lookahead are paid from the declared fixed delay. Runs on worker I/O threads.
class Resampler {
    static constexpr unsigned taps=64,phases=1024,history=128;
    unsigned channelCount,inputRate,outputRate;
    uint64_t inputCount=0,outputCount=0;
    std::vector<float> samples,coefficients;
    std::array<float,10> frame{};
public:
    Resampler(unsigned count,unsigned inRate,unsigned outRate):channelCount(count),inputRate(inRate),outputRate(outRate),samples(history*count,0),coefficients(phases*taps){
        const double cutoff=std::min(1.0,double(outRate)/inRate)*0.94;
        for(unsigned phase=0;phase<phases;phase++){
            double sum=0;
            for(unsigned tap=0;tap<taps;tap++){
                const double x=double(int(tap)-31)-double(phase)/phases;
                const double sinc=std::abs(x)<1e-12?cutoff:std::sin(M_PI*cutoff*x)/(M_PI*x);
                const double window=0.42-0.5*std::cos(2*M_PI*tap/(taps-1))+0.08*std::cos(4*M_PI*tap/(taps-1));
                coefficients[phase*taps+tap]=float(sinc*window);sum+=sinc*window;
            }
            for(unsigned tap=0;tap<taps;tap++)coefficients[phase*taps+tap]/=float(sum);
        }
    }
    template<class Emit> bool feed(const float *source,unsigned count,Emit emit){
        for(unsigned n=0;n<count;n++){
            if(inputRate==outputRate){if(!emit(source+n*channelCount,int64_t(outputCount++)))return false;inputCount++;continue;}
            std::copy_n(source+n*channelCount,channelCount,samples.data()+(inputCount%history)*channelCount);inputCount++;
            for(;;){
                const long double position=static_cast<long double>(outputCount)*inputRate/outputRate;
                const int64_t center=int64_t(std::floor(position));
                if(center+32>=int64_t(inputCount))break;
                const unsigned phase=std::min(phases-1,unsigned((position-center)*phases));
                std::fill_n(frame.data(),channelCount,0.f);
                for(unsigned tap=0;tap<taps;tap++){
                    const int64_t index=center-31+tap;if(index<0)continue;
                    const float weight=coefficients[phase*taps+tap];
                    for(unsigned ch=0;ch<channelCount;ch++)frame[ch]+=samples[(uint64_t(index)%history)*channelCount+ch]*weight;
                }
                if(!emit(frame.data(),int64_t(outputCount++)))return false;
            }
        }
        return true;
    }
};

struct State {
    Ring<Packet<2>> input;
    Ring<Packet<10>> output;
    std::atomic<bool> admitted{false},warmReady{false},enabled{true},offline{false};
    std::atomic<unsigned> rate{48000},latencyFrames{26750},muteMask{0},soloMask{0};
    std::array<std::atomic<float>,5> gains{{1,1,1,1,1}};
    std::atomic<uint64_t> requestedEpoch{1},renderedFrames{0},underruns{0},overruns{0};
    std::atomic<int> fault{none};
    uint64_t epoch=0,position=0,dryPosition=0,dryEpochStart=0;
    int64_t expectedSample=0;bool hadSample=false;
    unsigned outputOffset=0;
    std::array<float,maxBlock*2> scratch{};
    // Maximum supported rate is 192 kHz; allocate once, before any callback.
    std::array<float,((modelDelay*192000ull+modelRate-1)/modelRate+maxBlock)*2> dry{};
    std::array<float,5> smoothed{{1,1,1,1,1}};
    float wet=1,ramp=0.01;
    void prepare(unsigned sampleRate){rate.store(sampleRate);latencyFrames.store(unsigned(std::ceil(double(modelDelay)*sampleRate/modelRate)));ramp=float(1-std::exp(-1.0/(0.003*sampleRate)));requestedEpoch.fetch_add(1);hadSample=false;}
    void setFault(Fault value){int expected=none;fault.compare_exchange_strong(expected,value);}
    bool waitAllowed(const std::chrono::steady_clock::time_point &deadline){
        if(!offline.load(std::memory_order_relaxed)||!admitted.load()||fault.load()!=none)return false;
        if(std::chrono::steady_clock::now()>=deadline){setFault(offlineTimeout);return false;}
        std::this_thread::sleep_for(std::chrono::milliseconds(1));return true;
    }
    void process(const float *left,const float *right,float *outLeft,float *outRight,unsigned count,const AudioTimeStamp *time){
        const bool accepted=admitted.load(std::memory_order_acquire);
        if(!accepted){std::copy_n(left,count,outLeft);std::copy_n(right,count,outRight);return;}
        const bool renderOffline=offline.load(std::memory_order_relaxed);
        const auto deadline=renderOffline?std::chrono::steady_clock::now()+std::chrono::seconds(30):std::chrono::steady_clock::time_point{};
        auto nextEpoch=requestedEpoch.load(std::memory_order_acquire);
        if(time&&(time->mFlags&kAudioTimeStampSampleTimeValid)){
            const auto sample=int64_t(std::llround(time->mSampleTime));
            if(hadSample&&sample!=expectedSample&&nextEpoch==epoch)nextEpoch=requestedEpoch.fetch_add(1)+1;
            expectedSample=sample+count;hadSample=true;
        }
        if(nextEpoch!=epoch){epoch=nextEpoch;position=0;dryEpochStart=dryPosition;outputOffset=0;renderedFrames.store(0);}
        if(!warmReady.load(std::memory_order_acquire)){
            // A model can take seconds to load. Do not overflow the audio queue
            // with a transport that has not yet been admitted to inference.
            while(renderOffline&&!warmReady.load()&&waitAllowed(deadline)){}
            if(!warmReady.load()){
                const auto delay=latencyFrames.load();const bool active=enabled.load();
                for(unsigned f=0;f<count;f++){
                    const auto frame=dryPosition+f;
                    const float dl=frame-dryEpochStart>=delay?dry[((frame-delay)%(dry.size()/2))*2]:0;
                    const float dr=frame-dryEpochStart>=delay?dry[((frame-delay)%(dry.size()/2))*2+1]:0;
                    dry[(frame%(dry.size()/2))*2]=left[f];dry[(frame%(dry.size()/2))*2+1]=right[f];
                    outLeft[f]=active?0:dl;outRight[f]=active?0:dr;
                }
                dryPosition+=count;wet=active?1.f:0.f;return;
            }
        }
        const unsigned delay=latencyFrames.load(std::memory_order_relaxed),sampleRate=rate.load(std::memory_order_relaxed);
        auto packet=input.producerSlot();
        while(!packet&&waitAllowed(deadline))packet=input.producerSlot();
        if(!packet){overruns.fetch_add(1,std::memory_order_relaxed);setFault(inputOverrun);}
        else if(fault.load()==none){
            packet->generation=epoch;packet->firstFrame=int64_t(position);packet->frames=count;packet->rate=sampleRate;
            for(unsigned f=0;f<count;f++){packet->samples[f*2]=left[f];packet->samples[f*2+1]=right[f];}
            input.publish();
        }
        const bool active=enabled.load(std::memory_order_relaxed);
        const unsigned muted=muteMask.load(std::memory_order_relaxed),solo=soloMask.load(std::memory_order_relaxed);
        std::array<float,5> target{};
        for(unsigned s=0;s<stems;s++)target[s]=((muted&(1u<<s))||(solo&&!(solo&(1u<<s))))?0:gains[s].load(std::memory_order_relaxed);
        for(unsigned f=0;f<count;f++){
            if(requestedEpoch.load(std::memory_order_acquire)!=epoch){outLeft[f]=0;outRight[f]=0;continue;}
            const uint64_t frame=position+f;
            const uint64_t dryFrame=dryPosition+f;
            const float dl=dryFrame-dryEpochStart>=delay?dry[((dryFrame-delay)%(dry.size()/2))*2]:0;
            const float dr=dryFrame-dryEpochStart>=delay?dry[((dryFrame-delay)%(dry.size()/2))*2+1]:0;
            dry[(dryFrame%(dry.size()/2))*2]=left[f];dry[(dryFrame%(dry.size()/2))*2+1]=right[f];
            float l=0,r=0;bool available=false;
            if(frame>=delay){
                const auto wanted=int64_t(frame-delay);
                for(unsigned attempts=0;attempts<=ringSlots;attempts++){
                    auto readyPacket=output.consumerSlot();
                    if(!readyPacket){if(active&&waitAllowed(deadline)){attempts--;continue;}break;}
                    if(readyPacket->generation<epoch||(readyPacket->generation==epoch&&readyPacket->firstFrame+readyPacket->frames<=wanted)){output.consume();outputOffset=0;continue;}
                    if(readyPacket->generation!=epoch||readyPacket->firstFrame>wanted)break;
                    outputOffset=unsigned(wanted-readyPacket->firstFrame);
                    for(unsigned s=0;s<stems;s++)smoothed[s]+=(target[s]-smoothed[s])*ramp;
                    // Define Other from the aligned original host PCM minus the
                    // first four separated sources. Unity is bit-exact delayed
                    // dry even after sample-rate conversion; mute/solo still
                    // controls that residual solely through the Other fader.
                    l=dl*smoothed[4];r=dr*smoothed[4];
                    for(unsigned s=0;s<4;s++){
                        const float gain=smoothed[s]-smoothed[4];
                        l+=readyPacket->samples[outputOffset*10+s*2]*gain;r+=readyPacket->samples[outputOffset*10+s*2+1]*gain;
                    }
                    if(++outputOffset==readyPacket->frames){output.consume();outputOffset=0;}
                    available=true;break;
                }
                if(!available&&active&&fault.load()==none){underruns.fetch_add(1,std::memory_order_relaxed);setFault(outputUnderrun);}
            }
            if(fault.load(std::memory_order_relaxed)!=none){l=0;r=0;if(active){outLeft[f]=0;outRight[f]=0;continue;}}
            wet+=((active?1.f:0.f)-wet)*ramp;
            outLeft[f]=l*wet+dl*(1-wet);outRight[f]=r*wet+dr*(1-wet);
        }
        position+=count;dryPosition+=count;renderedFrames.store(position,std::memory_order_release);
    }
};

std::atomic<bool> workerLease{false},offlineWorkerLease{false};
struct Runtime {
    std::shared_ptr<State> state;
    const bool offlineMode;
    std::atomic<bool> cancelled{false},finished{false};
    std::atomic<uint64_t> wireEpoch{0},flushedEpoch{0},completed{0};
    std::mutex messageMutex;std::string message;
    int inputFD=-1,outputFD=-1;
    Runtime(std::shared_ptr<State> value):state(std::move(value)),offlineMode(state->offline.load()){}
    void fail(Fault code,const std::string &text){state->setFault(code);{std::lock_guard<std::mutex> lock(messageMutex);message=text;}cancelled.store(true);}
    bool interrupted(){return cancelled.load(std::memory_order_relaxed)||state->fault.load()!=none;}
    bool transfer(int fd,void *data,size_t size,bool writing,bool header=false){
        auto *bytes=static_cast<uint8_t*>(data);size_t done=0;
        auto started=std::chrono::steady_clock::now();
        while(done<size&&!interrupted()){
            pollfd event{fd,short(writing?POLLOUT:POLLIN),0};
            const int result=poll(&event,1,50);
            if(result<0){if(errno==EINTR)continue;return false;}
            const auto elapsed=std::chrono::steady_clock::now()-started;
            const bool idleHeader=header&&done==0&&state->warmReady.load()&&completed.load()==sent.load();
            if(!idleHeader&&elapsed>std::chrono::seconds(state->warmReady.load()?10:60)){fail(protocolFailure,"O motor CatStem não respondeu dentro do prazo.");return false;}
            if(!result)continue;
            if(event.revents&(POLLERR|POLLNVAL))return false;
            if(!(event.revents&(writing?POLLOUT:POLLIN))){if(event.revents&POLLHUP)return false;continue;}
            const ssize_t count=writing ? ::write(fd,bytes+done,size-done) : ::read(fd,bytes+done,size-done);
            if(count<0){if(errno==EAGAIN||errno==EWOULDBLOCK||errno==EINTR)continue;return false;}
            if(count==0)return false;done+=size_t(count);
        }
        return done==size;
    }
    std::atomic<uint64_t> sent{0};
    bool send(Header &header,const void *payload=nullptr){return transfer(inputFD,&header,sizeof(header),true)&&(!header.payloadBytes||transfer(inputFD,const_cast<void*>(payload),header.payloadBytes,true));}
    void writer(){
        std::unique_ptr<Resampler> resampler;
        std::array<float,hop*2> pcm{};unsigned filled=0,currentRate=0;uint64_t generation=0,sequence=0;
        while(!interrupted()){
            if(!state->warmReady.load()){std::this_thread::sleep_for(std::chrono::milliseconds(1));continue;}
            const auto requested=state->requestedEpoch.load();
            if(requested!=generation){
                generation=requested;sequence=0;filled=0;resampler.reset();currentRate=0;
                wireEpoch.store(generation);completed.store(0);sent.store(0);
                Header command;command.type=flush;command.generation=generation;
                if(!send(command)){if(!interrupted())fail(backendFailure,"Falha ao reiniciar o fluxo CatStem.");break;}
            }
            if(flushedEpoch.load()!=generation){std::this_thread::sleep_for(std::chrono::milliseconds(1));continue;}
            auto packet=state->input.consumerSlot();
            if(!packet){std::this_thread::sleep_for(std::chrono::milliseconds(1));continue;}
            if(packet->generation!=generation){state->input.consume();continue;}
            if(!resampler){currentRate=packet->rate;resampler=std::make_unique<Resampler>(2,currentRate,modelRate);}
            if(currentRate!=packet->rate){fail(protocolFailure,"A taxa de áudio mudou sem reiniciar o fluxo CatStem.");break;}
            const bool completedBlock=resampler->feed(packet->samples.data(),packet->frames,[&](const float *frame,int64_t){
                if(state->requestedEpoch.load()!=generation||interrupted())return false;
                pcm[filled*2]=frame[0];pcm[filled*2+1]=frame[1];
                if(++filled<hop)return true;
                while(sequence-completed.load()>=2&&!interrupted()&&state->requestedEpoch.load()==generation)std::this_thread::sleep_for(std::chrono::milliseconds(1));
                if(interrupted()||state->requestedEpoch.load()!=generation)return false;
                Header command;command.type=audio;command.generation=generation;command.sequence=sequence;command.firstFrame=int64_t(sequence*hop);command.frames=hop;command.payloadBytes=sizeof(pcm);
                sent.store(sequence+1);
                if(!send(command,pcm.data())){if(!interrupted())fail(backendFailure,"Falha ao enviar áudio para o CatStem.");return false;}
                sequence++;filled=0;return true;
            });
            state->input.consume();
            if(!completedBlock&&interrupted())break;
        }
    }
    void reader(){
        std::vector<uint8_t> payload(hop*10*sizeof(float));
        std::unique_ptr<Resampler> resampler;
        Packet<10> pending;uint64_t generation=0,sequence=0;unsigned pendingCount=0,currentRate=0;
        auto publish=[&]()->bool{
            auto start=std::chrono::steady_clock::now();
            while(!interrupted()){
                if(state->requestedEpoch.load()!=generation)return false;
                if(auto target=state->output.producerSlot()){
                    target->generation=generation;target->firstFrame=pending.firstFrame;target->frames=pendingCount;target->rate=currentRate;
                    std::copy_n(pending.samples.data(),pendingCount*10,target->samples.data());state->output.publish();pendingCount=0;return true;
                }
                if(std::chrono::steady_clock::now()-start>std::chrono::seconds(30)){fail(protocolFailure,"A fila de saída do CatStem não foi consumida.");return false;}
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
            }
            return false;
        };
        while(!interrupted()){
            Header header;
            if(!transfer(outputFD,&header,sizeof(header),false,true)){if(!interrupted())fail(backendFailure,"O motor CatStem encerrou sem resposta.");break;}
            if(std::memcmp(header.magic,"CST1",4)||header.version!=1||header.flags||header.reserved||header.payloadBytes>payload.size()){
                fail(protocolFailure,"Resposta inválida do motor CatStem.");break;
            }
            if(header.payloadBytes&&!transfer(outputFD,payload.data(),header.payloadBytes,false)){if(!interrupted())fail(protocolFailure,"Resposta incompleta do motor CatStem.");break;}
            if(header.type==ready||header.type==error){
                if(header.payloadBytes>65536){fail(protocolFailure,"Mensagem de controle CatStem muito grande.");break;}
                NSData *data=[NSData dataWithBytes:payload.data() length:header.payloadBytes];
                id parsed=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if(![parsed isKindOfClass:NSDictionary.class]){fail(protocolFailure,"Mensagem de controle CatStem inválida.");break;}
                NSDictionary *info=parsed;
                if(header.type==error){
                    if(header.generation&&header.generation<state->requestedEpoch.load())continue;
                    NSString *text=[info[@"message"] isKindOfClass:NSString.class]?info[@"message"]:@"Falha no motor CatStem.";fail(backendFailure,text.UTF8String?:"Falha no motor CatStem.");break;
                }
                auto number=[&](NSString *key)->uint64_t{
                    id value=info[key];if(![value isKindOfClass:NSNumber.class])return UINT64_MAX;
                    const double numeric=[value doubleValue];
                    return std::isfinite(numeric)&&numeric>=0&&numeric<=UINT32_MAX&&std::floor(numeric)==numeric?uint64_t(numeric):UINT64_MAX;
                };
                if(state->warmReady.load()||number(@"protocolVersion")!=1||number(@"sampleRate")!=modelRate||number(@"hopFrames")!=hop||number(@"contextFrames")!=modelRate||number(@"rightContextFrames")!=rightContext||number(@"channels")!=2||number(@"stems")!=5||number(@"latencyFrames")!=modelDelay||number(@"maxStreams")!=1||number(@"offlineRendering")!=uint64_t(offlineMode)||![info[@"outputNames"] isEqual:@[@"Vocal",@"Drum",@"Bass",@"Guitar",@"Other"]]){fail(protocolFailure,"O motor CatStem usa uma configuração incompatível.");break;}
                state->warmReady.store(true,std::memory_order_release);continue;
            }
            if(header.stream!=1){fail(protocolFailure,"Identificador de fluxo CatStem inválido.");break;}
            if(header.type==flushed){
                if(header.payloadBytes||header.sequence||header.firstFrame||header.generation>wireEpoch.load()){fail(protocolFailure,"Confirmação de reinício CatStem inválida.");break;}
                if(header.generation==wireEpoch.load())flushedEpoch.store(header.generation);
                continue;
            }
            if(header.type!=output||header.frames!=hop||header.channels!=2||header.stems!=5||header.sampleRate!=modelRate||header.payloadBytes!=hop*10*sizeof(float)){
                fail(protocolFailure,"Bloco de áudio CatStem inválido.");break;
            }
            if(header.generation!=state->requestedEpoch.load()||header.generation!=wireEpoch.load())continue;
            if(generation!=header.generation){generation=header.generation;sequence=0;pendingCount=0;currentRate=state->rate.load();resampler=std::make_unique<Resampler>(10,modelRate,currentRate);}
            if(header.sequence!=sequence||header.firstFrame!=int64_t(sequence*hop)-rightContext){fail(protocolFailure,"O CatStem retornou áudio fora de sequência.");break;}
            const float *source=reinterpret_cast<const float*>(payload.data());
            const unsigned skip=header.firstFrame<0?unsigned(std::min<int64_t>(hop,-header.firstFrame)):0;
            bool accepted=true;
            for(unsigned f=skip;f<hop&&accepted;f++){
                std::array<float,10> frame{};
                for(unsigned s=0;s<stems;s++)for(unsigned ch=0;ch<2;ch++){
                    const float sample=source[s*hop*2+f*2+ch];
                    if(!std::isfinite(sample)){fail(protocolFailure,"O CatStem retornou áudio não finito.");accepted=false;break;}
                    frame[s*2+ch]=sample;
                }
                if(!accepted)break;
                accepted=resampler->feed(frame.data(),1,[&](const float *values,int64_t index){
                    if(state->requestedEpoch.load()!=generation||interrupted())return false;
                    if(!pendingCount)pending.firstFrame=index;
                    std::copy_n(values,10,pending.samples.data()+pendingCount*10);
                    return ++pendingCount<maxBlock||publish();
                });
            }
            if(accepted&&pendingCount)accepted=publish();
            if(accepted){sequence++;completed.store(sequence,std::memory_order_release);}
        }
    }
    void run(NSURL *executable,NSURL *worker,NSURL *modelCache){
        @autoreleasepool {
            NSTask *task=[[NSTask alloc]init];NSPipe *input=[NSPipe pipe],*output=[NSPipe pipe];
            task.executableURL=executable;task.arguments=offlineMode?@[@"-I",@"-B",@"-u",worker.path,@"--model-cache",modelCache.path,@"--offline"]:@[@"-I",@"-B",@"-u",worker.path,@"--model-cache",modelCache.path];
            task.standardInput=input;task.standardOutput=output;task.standardError=[NSFileHandle fileHandleWithNullDevice];
            NSMutableDictionary *environment=[NSProcessInfo.processInfo.environment mutableCopy];
            for(NSString *key in environment.allKeys)if([key hasPrefix:@"PYTHON"])[environment removeObjectForKey:key];
            environment[@"OMP_NUM_THREADS"]=@"2";environment[@"OPENBLAS_NUM_THREADS"]=@"2";task.environment=environment;
            NSError *launchError=nil;
            if(![task launchAndReturnError:&launchError])fail(backendFailure,launchError.localizedDescription.UTF8String?:"Não foi possível iniciar o motor CatStem.");
            else {
                inputFD=input.fileHandleForWriting.fileDescriptor;outputFD=output.fileHandleForReading.fileDescriptor;
                fcntl(inputFD,F_SETFL,fcntl(inputFD,F_GETFL)|O_NONBLOCK);fcntl(outputFD,F_SETFL,fcntl(outputFD,F_GETFL)|O_NONBLOCK);
                fcntl(inputFD,F_SETNOSIGPIPE,1);
                std::thread inputThread([this]{@autoreleasepool{writer();}}),outputThread([this]{@autoreleasepool{reader();}});
                inputThread.join();cancelled.store(true);outputThread.join();
                [input.fileHandleForWriting closeFile];[output.fileHandleForReading closeFile];
                if(task.running)[task terminate];
                for(unsigned i=0;i<100&&task.running;i++)std::this_thread::sleep_for(std::chrono::milliseconds(10));
                if(task.running)kill(task.processIdentifier,SIGKILL);
                [task waitUntilExit];
            }
            state->warmReady.store(false);(offlineMode?offlineWorkerLease:workerLease).store(false,std::memory_order_release);finished.store(true,std::memory_order_release);
        }
    }
};
}

@interface JarasStemAudioUnit : AUAudioUnit {
@public std::shared_ptr<CatStemRealtime::State> state;
    std::shared_ptr<CatStemRealtime::Runtime> runtime;
    AUAudioUnitBus *_input,*_output;AUAudioUnitBusArray *_inputs,*_outputs;
}
@end
@implementation JarasStemAudioUnit
- (instancetype)initWithComponentDescription:(AudioComponentDescription)d options:(AudioComponentInstantiationOptions)o error:(NSError **)e {
    if((self=[super initWithComponentDescription:d options:o error:e])){
        state=std::make_shared<CatStemRealtime::State>();
        AVAudioFormat *format=[[AVAudioFormat alloc]initStandardFormatWithSampleRate:48000 channels:2];
        _input=[[AUAudioUnitBus alloc]initWithFormat:format error:e];_output=[[AUAudioUnitBus alloc]initWithFormat:format error:e];
        _inputs=[[AUAudioUnitBusArray alloc]initWithAudioUnit:self busType:AUAudioUnitBusTypeInput busses:@[_input]];_outputs=[[AUAudioUnitBusArray alloc]initWithAudioUnit:self busType:AUAudioUnitBusTypeOutput busses:@[_output]];
        self.maximumFramesToRender=CatStemRealtime::maxBlock;
    }return self;
}
- (AUAudioUnitBusArray *)inputBusses{return _inputs;}
- (AUAudioUnitBusArray *)outputBusses{return _outputs;}
- (NSTimeInterval)latency{return state->admitted.load()?double(state->latencyFrames.load())/state->rate.load():0;}
- (void)reset{[super reset];state->requestedEpoch.fetch_add(1);}
- (BOOL)allocateRenderResourcesAndReturnError:(NSError **)error {
    const auto rate=_output.format.sampleRate;
    if(_input.format.channelCount!=2||_output.format.channelCount!=2||_input.format.sampleRate!=rate||_output.format.interleaved||_input.format.interleaved||_input.format.commonFormat!=AVAudioPCMFormatFloat32||_output.format.commonFormat!=AVAudioPCMFormatFloat32||rate<8000||rate>192000||std::abs(rate-std::round(rate))>.001){
        if(error)*error=[NSError errorWithDomain:@"CatStemSeparation" code:1 userInfo:@{NSLocalizedDescriptionKey:@"CatStem requires stereo Float32 audio at a supported sample rate."}];return NO;
    }
    if(![super allocateRenderResourcesAndReturnError:error])return NO;
    state->prepare(unsigned(std::round(rate)));state->offline.store(self.isRenderingOffline);return YES;
}
- (AUInternalRenderBlock)internalRenderBlock {
    auto *kernel=state.get();
    return ^AUAudioUnitStatus(AudioUnitRenderActionFlags *flags,const AudioTimeStamp *time,AVAudioFrameCount count,NSInteger bus,AudioBufferList *out,const AURenderEvent *events,AURenderPullInputBlock pull){
        if(count>CatStemRealtime::maxBlock)return kAudioUnitErr_TooManyFramesToProcess;
        if(!pull)return kAudioUnitErr_NoConnection;
        struct{UInt32 count;AudioBuffer buffers[2];}input{2,{{1,UInt32(count*sizeof(float)),kernel->scratch.data()},{1,UInt32(count*sizeof(float)),kernel->scratch.data()+CatStemRealtime::maxBlock}}};
        auto result=pull(flags,time,count,0,reinterpret_cast<AudioBufferList*>(&input));if(result!=noErr)return result;
        if(out->mNumberBuffers!=2)return kAudioUnitErr_FormatNotSupported;
        for(unsigned ch=0;ch<2;ch++){if(!out->mBuffers[ch].mData)out->mBuffers[ch].mData=kernel->scratch.data()+ch*CatStemRealtime::maxBlock;out->mBuffers[ch].mDataByteSize=count*sizeof(float);}
        kernel->process(static_cast<float*>(input.buffers[0].mData),static_cast<float*>(input.buffers[1].mData),static_cast<float*>(out->mBuffers[0].mData),static_cast<float*>(out->mBuffers[1].mData),count,time);
        if(flags)*flags&=~kAudioUnitRenderAction_OutputIsSilence;return noErr;
    };
}
- (void)dealloc{state->admitted.store(false);if(runtime)runtime->cancelled.store(true);}
@end

@implementation JarasStemSeparator
+ (AVAudioUnitEffect *)makeNode {
    static dispatch_once_t once;AudioComponentDescription d={kAudioUnitType_Effect,'CSt5','Jara',0,0};
    dispatch_once(&once,^{[AUAudioUnit registerSubclass:JarasStemAudioUnit.class asComponentDescription:d name:@"CatStemSeparation 5" version:1];});
    return [[AVAudioUnitEffect alloc]initWithAudioComponentDescription:d];
}
+ (BOOL)start:(AVAudioUnitEffect *)node executable:(NSURL *)executable worker:(NSURL *)worker modelCache:(NSURL *)modelCache error:(NSError **)error {
    auto *unit=(JarasStemAudioUnit *)node.AUAudioUnit;
    if(unit->runtime&&!unit->runtime->cancelled.load()&&unit->state->admitted.load())return YES;
    BOOL directory=NO;
    NSString *failure=nil;
    if(![NSFileManager.defaultManager isExecutableFileAtPath:executable.path]||![NSFileManager.defaultManager fileExistsAtPath:worker.path]||![NSFileManager.defaultManager fileExistsAtPath:modelCache.path isDirectory:&directory]||!directory)failure=@"O motor contínuo CatStem não está incluído nesta instalação.";
    bool expected=false;
    auto &lease=unit->state->offline.load()?CatStemRealtime::offlineWorkerLease:CatStemRealtime::workerLease;
    if(!failure&&!lease.compare_exchange_strong(expected,true))failure=unit->state->offline.load()?@"A exportação admite um CatStem ativo por vez. Há outro processamento offline em andamento.":@"O motor CatStem já está processando outra pista. Esta instância permanece em bypass.";
    if(failure){if(error)*error=[NSError errorWithDomain:@"CatStemSeparation" code:2 userInfo:@{NSLocalizedDescriptionKey:failure}];return NO;}
    unit->state->fault.store(CatStemRealtime::none);unit->state->warmReady.store(false);unit->state->requestedEpoch.fetch_add(1);unit->state->admitted.store(true);
    auto runtime=std::make_shared<CatStemRealtime::Runtime>(unit->state);unit->runtime=runtime;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{runtime->run(executable,worker,modelCache);});return YES;
}
+ (void)configure:(AVAudioUnitEffect *)node enabled:(BOOL)enabled gains:(NSArray<NSNumber *> *)gains muteMask:(NSUInteger)muteMask soloMask:(NSUInteger)soloMask {
    auto &state=*((JarasStemAudioUnit *)node.AUAudioUnit)->state;
    for(unsigned s=0;s<5;s++){double value=s<gains.count?gains[s].doubleValue:1;state.gains[s].store(float(std::isfinite(value)?std::clamp(value,0.0,4.0):0));}
    state.muteMask.store(unsigned(muteMask)&31);state.soloMask.store(unsigned(soloMask)&31);state.enabled.store(enabled);
}
+ (void)invalidate:(AVAudioUnitEffect *)node {((JarasStemAudioUnit *)node.AUAudioUnit)->state->requestedEpoch.fetch_add(1);}
+ (void)stop:(AVAudioUnitEffect *)node {auto *unit=(JarasStemAudioUnit *)node.AUAudioUnit;unit->state->admitted.store(false);unit->state->requestedEpoch.fetch_add(1);if(unit->runtime)unit->runtime->cancelled.store(true);}
+ (BOOL)stopAndWait:(AVAudioUnitEffect *)node timeout:(NSTimeInterval)timeout error:(NSError **)error {
    auto *unit=(JarasStemAudioUnit *)node.AUAudioUnit;
    if(!unit->state->offline.load()||NSThread.isMainThread){if(error)*error=[NSError errorWithDomain:@"CatStemSeparation" code:3 userInfo:@{NSLocalizedDescriptionKey:@"A espera pelo CatStem é exclusiva da tarefa de exportação offline."}];return NO;}
    [self stop:node];
    const auto deadline=std::chrono::steady_clock::now()+std::chrono::milliseconds(int64_t(std::clamp(std::isfinite(timeout)?timeout:0.0,0.0,10.0)*1000));
    while(unit->runtime&&!unit->runtime->finished.load(std::memory_order_acquire)){
        if(std::chrono::steady_clock::now()>=deadline){if(error)*error=[NSError errorWithDomain:@"CatStemSeparation" code:4 userInfo:@{NSLocalizedDescriptionKey:@"O motor CatStem não encerrou dentro do prazo."}];return NO;}
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    return YES;
}
+ (void)setOfflineRendering:(AVAudioUnitEffect *)node enabled:(BOOL)enabled {
    auto *unit=(JarasStemAudioUnit *)node.AUAudioUnit;
    if(unit->runtime&&unit->state->admitted.load()&&unit->runtime->offlineMode!=bool(enabled)){unit->runtime->fail(CatStemRealtime::protocolFailure,"Reinicie o motor CatStem para mudar o modo de renderização.");return;}
    unit->state->offline.store(enabled);node.AUAudioUnit.renderingOffline=enabled;
}
+ (NSDictionary<NSString *,id> *)status:(AVAudioUnitEffect *)node {
    auto *unit=(JarasStemAudioUnit *)node.AUAudioUnit;auto &state=*unit->state;
    const int fault=state.fault.load();const bool admitted=state.admitted.load(),ready=state.warmReady.load();
    NSString *phase=!admitted?@"stopped":fault?@"fault":!ready?@"loading":!state.enabled.load()?@"bypassed":state.renderedFrames.load()<state.latencyFrames.load()?@"priming":@"running";
    NSString *message=@"";
    if(unit->runtime){std::lock_guard<std::mutex> lock(unit->runtime->messageMutex);message=[NSString stringWithUTF8String:unit->runtime->message.c_str()];}
    if(!message.length&&fault){message=fault==CatStemRealtime::inputOverrun?@"O CatStem não conseguiu acompanhar a entrada de áudio.":fault==CatStemRealtime::outputUnderrun?@"O CatStem não entregou o áudio dentro da latência prevista.":fault==CatStemRealtime::offlineTimeout?@"O processamento offline CatStem excedeu o tempo limite.":@"O processamento CatStem foi interrompido.";}
    return @{@"state":phase,@"ready":@(ready&&fault==0),@"error":message,@"latencyFrames":@(admitted?state.latencyFrames.load():0),@"latencySeconds":@(node.AUAudioUnit.latency),@"underruns":@(state.underruns.load()),@"overruns":@(state.overruns.load()),@"generation":@(state.requestedEpoch.load())};
}
@end
#endif
