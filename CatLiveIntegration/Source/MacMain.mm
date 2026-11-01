#import <AppKit/AppKit.h>
#include "Bridge.h"
@interface IntegrationDelegate : NSObject<NSApplicationDelegate,NSWindowDelegate> {
    std::unique_ptr<integration::Bridge> bridge;
    std::vector<integration::Adapter> adapters;
    NSWindow* window; NSPopUpButton* selector; NSButton* button; NSTextField* status;
    NSTimer* timer; BOOL busy; NSString* failure;
}
@end
@implementation IntegrationDelegate
- (void)applicationDidFinishLaunching:(NSNotification*)note {
    bridge=std::make_unique<integration::Bridge>();
    window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,540,310) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable backing:NSBackingStoreBuffered defer:NO];
    window.title=@"CatLive Integration";window.delegate=self;window.backgroundColor=[NSColor colorWithWhite:0.10 alpha:1];window.appearance=[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    auto title=[NSTextField labelWithString:@"CatLive Integration"];title.font=[NSFont systemFontOfSize:26 weight:NSFontWeightSemibold];title.alignment=NSTextAlignmentCenter;title.frame=NSMakeRect(20,236,500,38);[window.contentView addSubview:title];
    auto label=[NSTextField labelWithString:@"Adaptador Ethernet (RJ45)"];label.font=[NSFont systemFontOfSize:13];label.textColor=NSColor.secondaryLabelColor;label.frame=NSMakeRect(65,190,410,22);[window.contentView addSubview:label];
    selector=[[NSPopUpButton alloc]initWithFrame:NSMakeRect(60,151,420,34) pullsDown:NO];[window.contentView addSubview:selector];
    button=[NSButton buttonWithTitle:@"Iniciar conexão" target:self action:@selector(toggle:)];button.bezelStyle=NSBezelStyleRounded;button.frame=NSMakeRect(170,99,200,38);button.font=[NSFont systemFontOfSize:15 weight:NSFontWeightSemibold];[window.contentView addSubview:button];
    status=[NSTextField wrappingLabelWithString:@""];status.font=[NSFont systemFontOfSize:12];status.textColor=NSColor.secondaryLabelColor;status.alignment=NSTextAlignmentCenter;status.frame=NSMakeRect(30,20,480,65);[window.contentView addSubview:status];
    [self refreshAdapters];timer=[NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(update:) userInfo:nil repeats:YES];
    [window center];[window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];
}
- (void)refreshAdapters {
    id old=selector.selectedItem.representedObject;auto found=integration::adapters();
    bool changed=found.size()!=adapters.size();if(!changed)for(size_t i=0;i<found.size();++i)if(found[i].address!=adapters[i].address||found[i].name!=adapters[i].name)changed=true;
    if(!changed&&selector.numberOfItems)return;adapters=std::move(found);[selector removeAllItems];
    for(auto& adapter:adapters){NSString* title=[NSString stringWithFormat:@"%s · %s",adapter.name.c_str(),adapter.address.c_str()];[selector addItemWithTitle:title];selector.lastItem.representedObject=[NSString stringWithUTF8String:adapter.address.c_str()];}
    if(old)for(NSMenuItem* item in selector.itemArray)if([item.representedObject isEqual:old])[selector selectItem:item];
    if(adapters.empty())[selector addItemWithTitle:@"Conecte um adaptador Ethernet"];
}
- (void)toggle:(id)sender {
    if(busy)return;bool running=bridge->status()["running"];NSInteger index=selector.indexOfSelectedItem;
    if(!running&&(index<0||index>=NSInteger(adapters.size())))return;
    failure=nil;busy=YES;button.enabled=NO;selector.enabled=NO;status.stringValue=running?@"Encerrando conexão…":@"Iniciando conexão…";
    std::string address=running?"":adapters[index].address;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        std::string error;try{if(running)self->bridge->stop();else self->bridge->start(address);}catch(const std::exception& e){error=e.what();}
        dispatch_async(dispatch_get_main_queue(),^{self->busy=NO;if(!error.empty())self->failure=[NSString stringWithUTF8String:error.c_str()];[self update:nil];});
    });
}
- (void)update:(id)sender {
    if(busy)return;auto value=bridge->status();bool running=value["running"],connected=value["connected"];
    if(!running)[self refreshAdapters];selector.enabled=!running;button.enabled=running||!adapters.empty();button.title=running?@"Encerrar conexão":@"Iniciar conexão";
    if(running) {auto address=value["address"].get<std::string>();auto client=value["client"].get<std::string>();status.stringValue=connected?[NSString stringWithFormat:@"Conectado: %s\n%s · porta %d",client.c_str(),address.c_str(),integration::defaultPort]:[NSString stringWithFormat:@"Aguardando CatLive\n%s · porta %d",address.c_str(),integration::defaultPort];}
    else if(failure)status.stringValue=failure;
    else if(sender)status.stringValue=adapters.empty()?@"Conecte o cabo de rede para iniciar.":@"Escolha o adaptador usado para conectar ao CatLive.";
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)app{return YES;}
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication*)app{if(busy)return NSTerminateCancel;[timer invalidate];bridge->stop();return NSTerminateNow;}
@end
int main(int argc,const char* argv[]){@autoreleasepool{auto app=NSApplication.sharedApplication;auto delegate=[IntegrationDelegate new];app.delegate=delegate;[app setActivationPolicy:NSApplicationActivationPolicyRegular];[app run];}}
