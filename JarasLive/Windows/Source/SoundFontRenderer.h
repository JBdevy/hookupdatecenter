// Ported from Apple/Bridge/JarasSoundFont.mm; keep musical behaviour aligned.
#pragma once
struct MIDIMessage { uint8_t status,a,b; };
struct SoundFontRenderer {

    tsf *font = nullptr;
    std::array<MIDIMessage,2048> messages{};
    std::atomic<unsigned> written{0}, read{0};
    std::atomic<bool> silenceRequested{false};
    std::atomic<float> gain{1}, pan{0}, attack{0}, hold{10}, decay{10}, sustain{1}, release{.3};
    std::atomic<bool> monophonic{false}, drums{false};
    std::atomic<int> velocityCurve{1};
    std::atomic<bool> modulationEnabled{false}, pitchVibratoEnabled{false};
    std::array<float,16> modulationValues{{1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1}}, bendValues{};
    std::array<int,16> appliedPitch{{8192,8192,8192,8192,8192,8192,8192,8192,8192,8192,8192,8192,8192,8192,8192,8192}};
    double vibratoPhase=0;
    std::atomic<float> cutoff{20000}, velocityMinimum{20000}, filterAttack{0}, filterHold{0}, filterDecay{.3}, filterSustain{1}, filterRelease{.3}, filterDepth{0};
    struct FilterVoice { double age=0, releaseAge=0; float level=0, releaseLevel=0, frequency=-1; bool released=false; };
    std::array<FilterVoice,128> filters{};
    std::array<unsigned long long,2048> held{};
    std::array<uint8_t,2048> heldVelocity{};
    std::array<bool,2048> pressed{};
    std::array<bool,16> pedal{};
    unsigned long long order=0;
    int monoKey=-1;
    bool previousMono=false;
    float smoothGain=0, smoothPan=0;
    std::array<float,5> lastEnvelope{{-1,-1,-1,-1,-1}};
    ~SoundFontRenderer() { if (font) tsf_close(font); }
    void enqueue(MIDIMessage message) {
        const unsigned w=written.load(std::memory_order_relaxed), r=read.load(std::memory_order_acquire);
        if (w-r >= messages.size()) { silenceRequested.store(true); return; }
        messages[w % messages.size()]=message;
        written.store(w+1,std::memory_order_release);
    }
    void envelope() {
        const std::array<float,5> values{{attack.load(),hold.load(),decay.load(),sustain.load(),release.load()}};
        if (values==lastEnvelope) return;
        lastEnvelope=values;
        font->hookVolumeEnvelopeOverride=1;
        font->hookAttackSeconds=values[0];font->hookHoldSeconds=values[1];font->hookDecaySeconds=values[2];
        font->hookSustain=values[3];font->hookReleaseSeconds=values[4];
    }    static bool hiHat(int key) { return key==42 || key==44 || key==46; }
    void startNote(int channel, int key, uint8_t velocity) {
        if (drums.load() && hiHat(key)) {
            for(int i=0;i<font->voiceNum;++i) if(font->voices[i].playingPreset>=0 && hiHat(font->voices[i].playingKey)) tsf_voice_endquick(font,&font->voices[i]);
        }
        if(monophonic.load()) {
            for(int i=0;i<font->voiceNum;++i) if(font->voices[i].playingPreset>=0) tsf_voice_endquick(font,&font->voices[i]);
            monoKey=channel*128+key;
        }
        const int curve=velocityCurve.load();
        const float mapped=std::pow(velocity/127.f,curve==0?.65f:curve==2?1.6f:1.f);
        const auto generation=font->voicePlayIndex;
        tsf_channel_note_on(font,channel,key,std::max(1.f/127.f,mapped));
        for(int i=0;i<font->voiceNum && i<int(filters.size());++i) {
            auto& voice=font->voices[i];
            if(voice.playingPreset<0 || voice.playIndex!=generation) continue;
            voice.hookFilterVelocity=uint8_t(std::clamp(int(std::round(mapped*127)),1,127));
            filters[i]={};
        }
    }
    void noteOn(int channel,int key,uint8_t velocity) {
        const int index=channel*128+key;
        held[index]=++order; heldVelocity[index]=velocity; pressed[index]=true;
        startNote(channel,key,velocity);
    }
    void noteOff(int channel,int key) {
        const int index=channel*128+key;
        pressed[index]=false;
        if(!pedal[channel]) held[index]=0;
        tsf_channel_note_off(font,channel,key);
        if(monophonic.load() && index==monoKey && !held[index]) {
            int newest=-1; unsigned long long serial=0;
            for(int i=0;i<int(held.size());++i) if(held[i]>serial) { serial=held[i]; newest=i; }
            monoKey=-1;
            if(newest>=0) startNote(newest/128,newest%128,heldVelocity[newest]);
        }
    }
    void controllersForBlock(unsigned frames) {
        const bool enabled=pitchVibratoEnabled.load();
        const double wave=std::sin(vibratoPhase);
        vibratoPhase=std::fmod(vibratoPhase+2*3.14159265358979323846*6.85*frames/font->outSampleRate,2*3.14159265358979323846);
        for(int channel=0;channel<16;++channel) {
            // Full wheel travel gives 50 cents of vibrato; centered wheel is neutral.
            const int pitch=8192+(enabled?int(wave*std::abs(bendValues[channel])*2048):0);
            if(appliedPitch[channel]!=pitch) { tsf_channel_set_pitchwheel(font,channel,pitch); appliedPitch[channel]=pitch; }
        }
    }
    void filtersForBlock(unsigned frames) {
        const float ceiling=cutoff.load(), minimum=velocityMinimum.load(), depth=filterDepth.load();
        const float a=filterAttack.load(), h=filterHold.load(), d=filterDecay.load(), sustainLevel=filterSustain.load(), releaseTime=filterRelease.load();
        const double step=frames/double(font->outSampleRate);
        for(int i=0;i<font->voiceNum && i<int(filters.size());++i) {
            auto& voice=font->voices[i]; if(voice.playingPreset<0) continue;
            auto& state=filters[i];
            if(voice.ampenv.segment>=TSF_SEGMENT_RELEASE) {
                if(!state.released) { state.released=true; state.releaseLevel=state.level; }
                state.releaseAge+=step;
                state.level=state.releaseLevel*std::max(0.0,1-state.releaseAge/releaseTime);
            } else {
                state.age+=step;
                if(state.age<a && a>0) state.level=state.age/a;
                else if(state.age<a+h) state.level=1;
                else state.level=sustainLevel+(1-sustainLevel)*std::max(0.0,1-(state.age-a-h)/d);
            }
            const float velocityHz=minimum>=19999?20000:minimum*std::pow(20000/minimum,voice.hookFilterVelocity/127.f);
            const float controllerCeiling=modulationEnabled.load()?20*std::pow(ceiling/20,modulationValues[voice.playingChannel]):ceiling;
            const float base=std::min(controllerCeiling,velocityHz);
            const float desired=std::clamp(depth>0?base*std::pow(2.f,depth*(state.level-1)):base,20.f,20000.f);
            if(state.frequency==desired) continue;
            const float frequency=state.frequency<0?desired:state.frequency+(desired-state.frequency)*float(1-std::exp(-step/.004));
            if(state.frequency>=0 && std::abs(frequency-state.frequency)<.001f) continue;
            state.frequency=frequency;
            auto& filter=voice.hookCutoff;
            const bool active=frequency<19999;
            if(active!=bool(filter.active)) filter.z1=filter.z2=0;
            filter.active=active; filter.QInv=1.4142135623730951;
            if(active) tsf_voice_lowpass_setup(&filter,std::min(frequency/font->outSampleRate,.45f));
        }
    }
};
