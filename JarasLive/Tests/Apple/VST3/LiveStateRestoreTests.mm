// Include the host to exercise the same publication and native editor lifetime
// used by the AU, with a deliberately suspended plugin process() call.
#import "../../../Apple/Bridge/JarasVST3.mm"
#include <dlfcn.h>
#include <thread>
#include <chrono>
#include <cassert>

static void require(bool value,const char *message){if(!value){fprintf(stderr,"FAILED: %s\n",message);abort();}}
int main(int argc,char **argv){@autoreleasepool{
    require(argc==3,"fixture paths");[NSApplication sharedApplication];
    NSString *path=@(argv[1]);
    auto library=dlopen([[path stringByAppendingPathComponent:@"Contents/MacOS/GainFixture"] UTF8String],RTLD_NOW);
    require(library,"load fixture");
    auto block=(void(*)())dlsym(library,"catliveBlockNextProcess");
    auto entered=(bool(*)())dlsym(library,"catliveProcessEntered");
    auto release=(void(*)())dlsym(library,"catliveReleaseProcess");
    auto overlaps=(unsigned(*)())dlsym(library,"catliveConcurrentStateWrites");
    auto destroyed=(unsigned(*)())dlsym(library,"catliveDestroyedWhileProcessing");
    require(block&&entered&&release&&overlaps&&destroyed,"fixture diagnostics");
    NSMutableDictionary *spec=[@{@"id":@"fixture",@"classID":@"1234123456785678ABCDEF0012345678",@"path":path,@"bypassed":@NO} mutableCopy];
    auto state=[](float value){return [[NSData dataWithBytes:&value length:sizeof(value)]base64EncodedStringWithOptions:0];};
    spec[@"componentState"]=state(.25f);spec[@"controllerState"]=state(.25f);
    auto node=[JarasVST3 makeNode];NSError *error=nil;
    require([JarasVST3 configure:node plugins:@[spec] error:&error],"initial configure");
    auto &kernel=((JarasVSTAudioUnit *)node.AUAudioUnit)->kernel;
    auto old=kernel.find(@"fixture");
    auto view=(JarasVSTEditorView *)[JarasVST3 editor:node identifier:@"fixture"];
    auto window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,400,300) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    auto container=[[NSView alloc]initWithFrame:NSMakeRect(0,0,400,300)];window.contentView=container;[container addSubview:view];[window orderFront:nil];
    [[NSRunLoop mainRunLoop]runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]];
    require(view->attached,"native editor attached");auto originalPlugView=view->plugView;
    __block unsigned edits=0,parameterEdits=0;
    [JarasVST3 onEdit:node identifier:@"fixture" action:^{++edits;}];
    [JarasVST3 onParameterEdit:node identifier:@"fixture" action:^(unsigned,double,BOOL){++parameterEdits;}];
    old->endEdit(0); // Callback already queued before Undo must be invalidated.
    constexpr unsigned frames=128;float left[frames],right[frames];
    struct StereoBuffers{UInt32 count;AudioBuffer channel[2];} buffer{2,{{1,sizeof(left),left},{1,sizeof(right),right}}};
    AudioTimeStamp time{};time.mFlags=kAudioTimeStampSampleTimeValid;
    auto render=[&]{std::fill_n(left,frames,.2f);std::fill_n(right,frames,.2f);kernel.process((AudioBufferList *)&buffer,frames,&time);time.mSampleTime+=frames;};
    block();std::thread audio(render);
    auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(3);
    while(!entered()&&std::chrono::steady_clock::now()<deadline)std::this_thread::sleep_for(std::chrono::milliseconds(1));
    require(entered(),"old process entered");
    spec[@"componentState"]=state(.75f);spec[@"controllerState"]=state(.75f);
    require([JarasVST3 configure:node plugins:@[spec] error:&error],"restore while old block runs");
    require(overlaps()==0,"setState must never touch the instance rendering audio");
    auto current=kernel.find(@"fixture");
    require(current!=old,"Undo prepares a replacement processor");
    require(view.superview==container&&view.window==window&&view->instance==current&&view->plugView!=originalPlugView&&view->attached,"rebind editor in the same Cocoa view and window");
    require(!old->editCallbacksActive->load(),"invalidate outgoing editor callbacks");
    release();audio.join();
    for(auto sample:left)require(fabs(sample-.05f)<1e-6,"in-flight block completes with previous preset");
    render();for(auto sample:left)require(fabs(sample-.15f)<1e-6,"next block uses new preset without silence");
    [[NSRunLoop mainRunLoop]runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]];
    require(edits==0&&parameterEdits==0,"discard queued edits from old controller");
    current->endEdit(0);
    [[NSRunLoop mainRunLoop]runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]];
    require(edits==1&&parameterEdits==1,"replacement retains edit callbacks");
    // A preset restore must chase pressed notes, and keep MIDI that arrived
    // between blocks. No control-thread read of the render-owned held bitmap.
    [JarasVST3 sendMIDI:node status:0x90 data1:60 data2:100];render();
    require(fabs(left[0]-.275f)<1e-6,"initial held MIDI note");
    auto restoreGain=[&](float value){spec[@"componentState"]=state(value);spec[@"controllerState"]=state(value);require([JarasVST3 configure:node plugins:@[spec] error:&error],"MIDI preset restore");};
    restoreGain(.4f);render();require(fabs(left[0]-.205f)<1e-6,"held note continues after replacement");
    [JarasVST3 sendMIDI:node status:0x80 data1:60 data2:0];render();require(fabs(left[0]-.08f)<1e-6,"note-off reaches replacement");
    [JarasVST3 sendMIDI:node status:0x90 data1:62 data2:91];restoreGain(.3f);render();
    require(fabs(left[0]-.185f)<1e-6,"pending note-on survives replacement");
    [JarasVST3 sendMIDI:node status:0x80 data1:62 data2:0];restoreGain(.2f);render();
    require(fabs(left[0]-.04f)<1e-6,"pending note-off prevents hanging replayed notes");
    [JarasVST3 sendMIDI:node status:0x90 data1:64 data2:77];render();
    restoreGain(.6f);restoreGain(.7f);render();require(fabs(left[0]-.265f)<1e-6,"multiple replacements before a render preserve held MIDI");
    [JarasVST3 sendMIDI:node status:0x80 data1:64 data2:0];render();
    [JarasVST3 sendMIDI:node status:0xB0 data1:64 data2:127];
    [JarasVST3 sendMIDI:node status:0x90 data1:65 data2:102];render();
    [JarasVST3 sendMIDI:node status:0x80 data1:65 data2:0];render();
    require(fabs(left[0]-.265f)<1e-6,"pedal keeps released key sounding");
    restoreGain(.5f);render();require(fabs(left[0]-.225f)<1e-6,"pedal-held note survives restore");
    [JarasVST3 sendMIDI:node status:0xB0 data1:64 data2:0];render();
    require(fabs(left[0]-.1f)<1e-6,"releasing pedal stops chased voice");
    [JarasVST3 sendMIDI:node status:0xB0 data1:64 data2:127];
    [JarasVST3 sendMIDI:node status:0x90 data1:67 data2:102];render();
    [JarasVST3 sendMIDI:node status:0x80 data1:67 data2:0];restoreGain(.6f);render();
    require(fabs(left[0]-.245f)<1e-6,"pending key release preserves pedal voice during restore");
    [JarasVST3 sendMIDI:node status:0xB0 data1:64 data2:0];render();require(fabs(left[0]-.12f)<1e-6,"pedal release after pending key release");
    current=kernel.find(@"fixture");
    printf("VST3_RESTORE_PRESERVES_SUSTAIN_PEDAL_RELEASED_AND_PENDING_RELEASE_NOTES_OK\n");
    printf("VST3_RESTORE_PRESERVES_HELD_PENDING_NOTE_ON_NOTE_OFF_AND_RAPID_REPLACEMENTS_OK\n");
    // Bypass and captured-state acknowledgement reuse the active processor.
    spec[@"bypassed"]=@YES;
    require([JarasVST3 configure:node plugins:@[spec] error:&error],"bypass");require(kernel.find(@"fixture")==current,"bypass must reuse processor");
    auto captured=[JarasVST3 state:node identifier:@"fixture"];
    spec[@"componentState"]=captured[@"componentState"];spec[@"controllerState"]=captured[@"controllerState"];
    require([JarasVST3 configure:node plugins:@[spec] error:&error],"acknowledge saved current preset");require(kernel.find(@"fixture")==current,"state capture must reuse processor");
    require(destroyed()==0,"no processor destruction during process");
    [view removeFromSuperview];[window orderOut:nil];
    require([JarasVST3 configure:node plugins:@[] error:&error],"clear chain");
    // This fixture has separate processor/controller objects. Updating only
    // controllerState must send restored values through IParameterChanges.
    NSMutableDictionary *separate=[spec mutableCopy];separate[@"path"]=@(argv[2]);separate[@"bypassed"]=@NO;
    separate[@"componentState"]=state(.25f);separate[@"controllerState"]=state(.25f);
    require([JarasVST3 configure:node plugins:@[separate] error:&error],"separate controller setup");
    render();require(fabs(left[0]-.05f)<1e-6,"separate processor initial state");
    separate[@"controllerState"]=state(.8f);
    require([JarasVST3 configure:node plugins:@[separate] error:&error],"controller-only restore");
    render();for(auto sample:left)require(fabs(sample-.16f)<1e-6,"restored controller parameters reach separate DSP processor");
    require([JarasVST3 configure:node plugins:@[] error:&error],"clear separate chain");
    printf("VST3_CONTROLLER_ONLY_RESTORE_REACHES_SEPARATE_PROCESSOR_PCM_OK\n");
    printf("VST3_LIVE_STATE_RESTORE_NO_CONCURRENT_SETSTATE_BLOCK_CONTINUITY_EDITOR_REBOUND_CALLBACKS_PRESERVED_OK\n");
    // Keep the fixture dlopen reference until host/module teardown completes.
    return 0;
}}
