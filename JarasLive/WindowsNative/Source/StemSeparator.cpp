#include "StemSeparator.h"
#include "StemSeparatorCore.h"
#include "../ThirdParty/nlohmann/json.hpp"
#include <windows.h>
#include <mutex>
#include <stdexcept>
namespace catlive::native::stem {
using namespace detail;
namespace {
std::atomic<unsigned> realtimeWorkers{0},offlineWorkers{0};
struct WorkerLease {
    std::atomic<unsigned> &counter;bool owns=false;
    explicit WorkerLease(bool offline):counter(offline?offlineWorkers:realtimeWorkers) { acquire(); }
    void acquire() {
        if(owns)return;
        auto count=counter.load();const unsigned limit=1;
        while(count<limit)if(counter.compare_exchange_weak(count,count+1)){owns=true;break;}
    }
    ~WorkerLease(){if(owns)--counter;}
};
struct Handle {
    HANDLE value=nullptr;
    ~Handle(){close();}
    void close(){if(value&&value!=INVALID_HANDLE_VALUE)CloseHandle(value);value=nullptr;}
    operator HANDLE()const{return value;}
};
// Only the pipe I/O threads call this. Windows Sleep(1) can round up to
// a 15.6-ms scheduler tick, repeatedly spending the model's delivery margin.
// Reuse a one-shot high-resolution timer without changing system timer policy
// or spinning. Neither the audio callback nor the model waits on this timer.
void pausePipeWorker() noexcept {
    struct Timer {
        Handle handle;
        Timer(){handle.value=CreateWaitableTimerExW(nullptr,nullptr,0x2,TIMER_MODIFY_STATE|SYNCHRONIZE);}
    };
    thread_local Timer timer;
    if(timer.handle.value) {
        LARGE_INTEGER due;due.QuadPart=-10000; // relative 1 ms, in 100-ns units
        if(SetWaitableTimer(timer.handle,&due,0,nullptr,nullptr,FALSE)&&
           WaitForSingleObject(timer.handle,INFINITE)==WAIT_OBJECT_0)return;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
}
std::wstring quote(const std::filesystem::path &path) {
    // Windows paths cannot contain quotes. The selected paths are app resources.
    return L"\""+path.wstring()+L"\"";
}
}
Paths Paths::bundled() {
    std::wstring path(32768,L'\0');const auto count=GetModuleFileNameW(nullptr,path.data(),DWORD(path.size()));
    if(!count||count>=path.size())return {};path.resize(count);
    const auto root=std::filesystem::path(path).parent_path()/L"StemSeparationRuntime";
    return {root/L"python/python.exe",root/L"stream_windows.py",root/L"5c90dfd2-34c22ccb.th"};
}
bool Paths::available()const {
    std::error_code e;return std::filesystem::is_regular_file(python,e)&&std::filesystem::is_regular_file(worker,e)&&std::filesystem::is_regular_file(model,e);
}
struct Processor::Impl {
    std::shared_ptr<State> state=std::make_shared<State>();
    Paths paths;
    const bool offlineMode;
    std::atomic<bool> requested{false},cancelled{false},finished{false};
    std::atomic<uint64_t> wireEpoch{0},flushedEpoch{0},completed{0};
    mutable std::mutex messageMutex;
    std::string message;
    HANDLE inputPipe=nullptr,outputPipe=nullptr;
    Impl(Paths p,unsigned rate,bool offline):paths(std::move(p)),offlineMode(offline) {
        state->prepare(rate);state->offline=offline;state->admitted=offline;
    }
    void fail(Fault code,const std::string &text){state->setFault(code);{std::lock_guard<std::mutex> lock(messageMutex);message=text;}cancelled.store(true);}
    bool interrupted(){return cancelled.load(std::memory_order_relaxed)||state->fault.load()!=none;}
    bool transfer(HANDLE pipe,void *data,size_t size,bool writing,bool header=false) {
        auto *bytes=static_cast<uint8_t*>(data);size_t done=0;
        auto lastProgress=std::chrono::steady_clock::now();
        while(done<size&&!interrupted()) {
            const bool idleHeader=header&&done==0&&state->warmReady.load()&&completed.load()==sent.load();
            if(idleHeader)lastProgress=std::chrono::steady_clock::now();
            if(!idleHeader&&std::chrono::steady_clock::now()-lastProgress>std::chrono::seconds(state->warmReady.load()?30:180)) {
                fail(protocolFailure,"O motor CatStem não respondeu dentro do prazo.");return false;
            }
            DWORD available=0,count=0;
            if(!writing) {
                if(!PeekNamedPipe(pipe,nullptr,0,nullptr,&available,nullptr))return false;
                if(!available){pausePipeWorker();continue;}
            }
            const auto amount=DWORD(std::min<size_t>(size-done,writing?4096:available));
            const bool ok=writing?WriteFile(pipe,bytes+done,amount,&count,nullptr):ReadFile(pipe,bytes+done,amount,&count,nullptr);
            if(!ok||!count)return false;done+=count;lastProgress=std::chrono::steady_clock::now();
        }
        return done==size;
    }
    std::atomic<uint64_t> sent{0};
    bool send(Header &header,const void *payload=nullptr){return transfer(inputPipe,&header,sizeof(header),true)&&(!header.payloadBytes||transfer(inputPipe,const_cast<void*>(payload),header.payloadBytes,true));}
    void writer(){
        std::unique_ptr<Resampler> resampler;
        std::array<float,hop*2> pcm{};unsigned filled=0,currentRate=0;uint64_t generation=0,sequence=0;
        while(!interrupted()){
            if(!state->warmReady.load()){pausePipeWorker();continue;}
            const auto requested=state->requestedEpoch.load();
            if(requested!=generation){
                generation=requested;sequence=0;filled=0;resampler.reset();currentRate=0;
                wireEpoch.store(generation);completed.store(0);sent.store(0);
                Header command;command.type=flush;command.generation=generation;
                if(!send(command)){if(!interrupted())fail(backendFailure,"Falha ao reiniciar o fluxo CatStem.");break;}
            }
            if(flushedEpoch.load()!=generation){pausePipeWorker();continue;}
            auto packet=state->input.consumerSlot();
            if(!packet){pausePipeWorker();continue;}
            if(packet->generation!=generation){state->input.consume();continue;}
            if(!resampler){currentRate=packet->rate;resampler=std::make_unique<Resampler>(2,currentRate,modelRate);}
            if(currentRate!=packet->rate){fail(protocolFailure,"A taxa de áudio mudou sem reiniciar o fluxo CatStem.");break;}
            const bool completedBlock=resampler->feed(packet->samples.data(),packet->frames,[&](const float *frame,int64_t){
                if(state->requestedEpoch.load()!=generation||interrupted())return false;
                pcm[filled*2]=frame[0];pcm[filled*2+1]=frame[1];
                if(++filled<hop)return true;
                while(sequence-completed.load()>=2&&!interrupted()&&state->requestedEpoch.load()==generation)pausePipeWorker();
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
                pausePipeWorker();
            }
            return false;
        };
        while(!interrupted()){
            Header header;
            if(!transfer(outputPipe,&header,sizeof(header),false,true)){if(!interrupted())fail(backendFailure,"O motor CatStem encerrou sem resposta.");break;}
            if(std::memcmp(header.magic,"CST1",4)||header.version!=1||header.flags||header.reserved||header.payloadBytes>payload.size()){
                fail(protocolFailure,"Resposta inválida do motor CatStem.");break;
            }
            if(header.payloadBytes&&!transfer(outputPipe,payload.data(),header.payloadBytes,false)){if(!interrupted())fail(protocolFailure,"Resposta incompleta do motor CatStem.");break;}
            if(header.type==ready||header.type==error){
                if(header.payloadBytes>65536){fail(protocolFailure,"Mensagem de controle CatStem muito grande.");break;}
                auto info=nlohmann::json::parse(payload.begin(),payload.begin()+header.payloadBytes,nullptr,false);
                if(!info.is_object()){fail(protocolFailure,"Mensagem de controle CatStem inválida.");break;}
                if(header.type==error){
                    if(header.generation&&header.generation<state->requestedEpoch.load())continue;
                    fail(backendFailure,info.value("message",std::string("Falha no motor CatStem.")));break;
                }
                auto number=[&](const char *key)->uint64_t {
                    auto it=info.find(key);if(it==info.end()||!it->is_number())return UINT64_MAX;
                    double value=it->get<double>();return std::isfinite(value)&&value>=0&&value<=UINT32_MAX&&std::floor(value)==value?uint64_t(value):UINT64_MAX;
                };
                if(state->warmReady.load()||number("protocolVersion")!=1||number("sampleRate")!=modelRate||number("hopFrames")!=hop||number("contextFrames")!=44100||number("rightContextFrames")!=rightContext||number("channels")!=2||number("stems")!=5||number("latencyFrames")!=modelDelay||number("maxStreams")!=1||(!info.contains("offlineRendering")||!info["offlineRendering"].is_boolean()||info["offlineRendering"].get<bool>()!=offlineMode)||info.value("sourceCheckpointSHA",std::string())!=modelSHA||info.value("outputNames",std::vector<std::string>{})!=std::vector<std::string>{"Vocal","Drum","Bass","Guitar","Other"}){fail(protocolFailure,"O motor CatStem usa uma configuração incompatível.");break;}
                state->warmReady.store(true,std::memory_order_release);continue;
            }
            if(header.stream!=1){fail(protocolFailure,"Identificador de fluxo CatStem inválido.");break;}
            if(header.type==flushed){
                if(header.payloadBytes||header.sequence||header.firstFrame||header.generation>wireEpoch.load()){fail(protocolFailure,"Confirmação de reinício CatStem inválida.");break;}
                if(header.generation==wireEpoch.load()){completed.store(0);flushedEpoch.store(header.generation);}
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
    void run() noexcept {
        try {
            while(!requested.load()&&!interrupted())std::this_thread::sleep_for(std::chrono::milliseconds(2));
            if(interrupted()){finished=true;return;}
            WorkerLease lease(offlineMode);
            // Device/rate changes replace the processor while the previous
            // child is shutting down asynchronously. Let that lease retire;
            // never report a second-instance error for the same live slot.
            const auto leaseDeadline=std::chrono::steady_clock::now()+std::chrono::seconds(6);
            while(!lease.owns&&!interrupted()&&std::chrono::steady_clock::now()<leaseDeadline){std::this_thread::sleep_for(std::chrono::milliseconds(2));lease.acquire();}
            if(interrupted()){finished=true;return;}
            if(!lease.owns)throw std::runtime_error("O limite de processamentos CatStem simultâneos foi atingido. Remova outro CatStem antes de ativar este.");
            if(!paths.available())throw std::runtime_error("O motor CatStem não está incluído nesta instalação.");
            SECURITY_ATTRIBUTES security{sizeof(SECURITY_ATTRIBUTES),nullptr,TRUE};
            Handle childIn,childOut,parentIn,parentOut,errorFile,process,thread,job;
            if(!CreatePipe(&childIn.value,&parentIn.value,&security,256*1024)||!CreatePipe(&parentOut.value,&childOut.value,&security,512*1024))throw std::runtime_error("Não foi possível abrir o fluxo CatStem.");
            SetHandleInformation(parentIn,HANDLE_FLAG_INHERIT,0);SetHandleInformation(parentOut,HANDLE_FLAG_INHERIT,0);
            errorFile.value=CreateFileW(L"NUL",GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE,&security,OPEN_EXISTING,0,nullptr);
            STARTUPINFOEXW startup{};startup.StartupInfo.cb=sizeof(startup);startup.StartupInfo.dwFlags=STARTF_USESTDHANDLES|STARTF_USESHOWWINDOW;startup.StartupInfo.wShowWindow=SW_HIDE;
            startup.StartupInfo.hStdInput=childIn;startup.StartupInfo.hStdOutput=childOut;startup.StartupInfo.hStdError=errorFile;
            SIZE_T bytes=0;InitializeProcThreadAttributeList(nullptr,1,0,&bytes);std::vector<uint8_t> attributes(bytes);
            startup.lpAttributeList=reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(attributes.data());
            if(!InitializeProcThreadAttributeList(startup.lpAttributeList,1,0,&bytes))throw std::runtime_error("Não foi possível preparar o motor CatStem.");
            struct AttributeCleanup{LPPROC_THREAD_ATTRIBUTE_LIST p;~AttributeCleanup(){DeleteProcThreadAttributeList(p);}} cleanup{startup.lpAttributeList};
            HANDLE handles[]{childIn.value,childOut.value,errorFile.value};
            if(!UpdateProcThreadAttribute(startup.lpAttributeList,0,PROC_THREAD_ATTRIBUTE_HANDLE_LIST,handles,sizeof(handles),nullptr,nullptr))throw std::runtime_error("Não foi possível isolar o fluxo CatStem.");
            auto command=quote(paths.python)+L" -I -B -u "+quote(paths.worker)+L" --model "+quote(paths.model)+(offlineMode?L" --offline":L"");
            PROCESS_INFORMATION info{};
            if(!CreateProcessW(paths.python.c_str(),command.data(),nullptr,nullptr,TRUE,CREATE_NO_WINDOW|CREATE_SUSPENDED|EXTENDED_STARTUPINFO_PRESENT,nullptr,paths.worker.parent_path().c_str(),&startup.StartupInfo,&info))throw std::runtime_error("Não foi possível iniciar o motor CatStem.");
            process.value=info.hProcess;thread.value=info.hThread;
            job.value=CreateJobObjectW(nullptr,nullptr);JOBOBJECT_EXTENDED_LIMIT_INFORMATION limit{};limit.BasicLimitInformation.LimitFlags=JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            if(!job.value||!SetInformationJobObject(job,JobObjectExtendedLimitInformation,&limit,sizeof(limit))||!AssignProcessToJobObject(job,process)) {TerminateProcess(process,1);throw std::runtime_error("Não foi possível proteger o processo CatStem.");}
            childIn.close();childOut.close();errorFile.close();inputPipe=parentIn;outputPipe=parentOut;
            ResumeThread(thread);thread.close();
            std::thread inputThread,outputThread;
            struct JoinWorkers {
                Impl &owner;HANDLE process;std::thread &input,&output;
                ~JoinWorkers() {
                    owner.cancelled=true;
                    // Child termination releases any pending synchronous write.
                    TerminateProcess(process,0);WaitForSingleObject(process,5000);
                    if(input.joinable()){CancelSynchronousIo(input.native_handle());input.join();}
                    if(output.joinable()){CancelSynchronousIo(output.native_handle());output.join();}
                }
            } joining{*this,process.value,inputThread,outputThread};
            inputThread=std::thread([this]{try{writer();}catch(const std::exception &e){fail(backendFailure,e.what());}});
            outputThread=std::thread([this]{try{reader();}catch(const std::exception &e){fail(backendFailure,e.what());}});
            while(!interrupted()) {
                if(WaitForSingleObject(process,20)==WAIT_OBJECT_0){fail(backendFailure,"O motor CatStem foi encerrado.");break;}
            }
            cancelled=true;
        }catch(const std::exception &e){fail(backendFailure,e.what());}
        state->warmReady=false;finished=true;
    }
};
Processor::Processor(Paths paths,unsigned rate,bool offline,bool prewarm):impl(std::make_shared<Impl>(std::move(paths),rate,offline)) {
    if(rate<32000||rate>192000)throw std::runtime_error("Taxa de áudio inválida para o CatStem.");
    impl->requested=prewarm;
    std::thread([owned=impl]{owned->run();}).detach();
}
Processor::~Processor(){
    impl->cancelled=true;
    // Offline jobs run consecutively on an export thread. Release their one
    // worker lease before the following file starts; never wait on the UI or
    // realtime callback when a realtime effect is removed.
    if(impl->offlineMode)while(!impl->finished.load())std::this_thread::sleep_for(std::chrono::milliseconds(1));
}
void Processor::configure(const Mix &mix) noexcept {
    if(impl->offlineMode&&!mix.enabled&&!impl->requested.load()&&!impl->state->warmReady.load())impl->state->admitted=false;
    impl->state->enabled=mix.enabled;impl->state->muteMask=mix.muteMask;impl->state->soloMask=mix.soloMask;
    for(unsigned s=0;s<5;s++)impl->state->gains[s]=std::isfinite(mix.gains[s])?std::clamp(mix.gains[s],0.f,4.f):1.f;
}
void Processor::process(float *left,float *right,unsigned count,double seconds,bool playing) noexcept {
    if(!left||!right||count>detail::maxBlock)return;
    if(!impl->requested.load()) {
        bool signal=playing;for(unsigned i=0;i<count&&!signal;i++)signal=std::abs(left[i])+std::abs(right[i])>1e-10f;
        if(signal&&impl->state->enabled.load())impl->requested=true;
    }
    impl->state->process(left,right,left,right,count,int64_t(std::llround(seconds*sampleRate())),playing);
}
unsigned Processor::latency()const noexcept{return impl->state->latencyFrames.load();}
unsigned Processor::availableLatency()const noexcept{return impl->state->admitted.load()?latency():0;}
void Processor::activate(bool force)noexcept{if(force||impl->state->warmReady.load())impl->state->admitted=true;}
bool Processor::pending()const noexcept{return impl->state->warmReady.load()&&!impl->state->admitted.load();}
void Processor::reset()noexcept{impl->state->requestedEpoch.fetch_add(1);}
unsigned Processor::sampleRate()const noexcept{return impl->state->rate.load();}
bool Processor::isOffline()const noexcept{return impl->offlineMode;}
Status Processor::status()const {
    Status result;const auto &s=*impl->state;
    const bool failed=s.fault.load()!=none,ready=s.warmReady.load();
    result.state=failed?"fault":!ready?"loading":!s.admitted.load()?"pending":!s.enabled.load()?"bypassed":s.renderedFrames.load()<s.latencyFrames.load()?"priming":"running";
    {std::lock_guard<std::mutex> lock(impl->messageMutex);result.error=impl->message;}
    if(failed&&result.error.empty())result.error="O processamento CatStem excedeu o tempo disponível. O áudio original foi preservado.";
    result.ready=ready&&!failed;result.workerRunning=impl->requested&&!impl->finished;result.latencyFrames=latency();result.underruns=s.underruns.load();result.overruns=s.overruns.load();return result;
}
void Processor::waitReady() {
    if(!isOffline())throw std::runtime_error("A espera CatStem só é permitida durante a exportação.");
    impl->requested=true;const auto start=std::chrono::steady_clock::now();
    while(!impl->state->warmReady.load()) {
        if(impl->state->fault.load()!=none)throw std::runtime_error(status().error);
        if(std::chrono::steady_clock::now()-start>std::chrono::seconds(180))throw std::runtime_error("CatStem demorou demais para iniciar.");
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
}
} // namespace catlive::native::stem
