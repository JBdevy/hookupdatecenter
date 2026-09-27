#import <Foundation/Foundation.h>
#import "../../Apple/Bridge/JarasCoreBridge.h"
#include <iostream>
#include <stdexcept>
static void expect(bool ok,const char* message){if(!ok) throw std::runtime_error(message);}
static bool equalJSON(id a,id b) {
    if([a isKindOfClass:NSNumber.class] && [b isKindOfClass:NSNumber.class]) return std::abs([a doubleValue]-[b doubleValue])<1e-12;
    if([a isKindOfClass:NSArray.class] && [b isKindOfClass:NSArray.class]) { if([a count]!=[b count]) return false; for(NSUInteger i=0;i<[a count];++i) if(!equalJSON(a[i],b[i])) return false; return true; }
    if([a isKindOfClass:NSDictionary.class] && [b isKindOfClass:NSDictionary.class]) { if([a count]!=[b count]) return false; for(id key in a) if(!b[key] || !equalJSON(a[key],b[key])) return false; return true; }
    return [a isEqual:b];
}
int main(int argc,char**argv){@autoreleasepool{
    expect(argc==2,"fixture required");
    NSData* input=[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]]; NSError* error=nil;
    JarasCoreBridge* core=[JarasCoreBridge new]; expect([core loadProjectData:input error:&error],"load bridge");
    NSDictionary* original=[NSJSONSerialization JSONObjectWithData:input options:0 error:&error];
    NSDictionary* snapshot=[NSJSONSerialization JSONObjectWithData:[core snapshotWithError:&error] options:0 error:&error];
    expect(equalJSON(original,snapshot[@"project"]),"bridge round trip preserves all fields and clips");
    expect([core executeCommand:@"play" target:nil value:0 error:&error],"main play");
    [core executeCommand:@"subSeek" target:nil value:20 error:&error]; [core executeCommand:@"subPlay" target:nil value:0 error:&error]; [core advance:2];
    NSDictionary* playback=[NSJSONSerialization JSONObjectWithData:[core playbackSnapshotWithError:&error] options:0 error:&error];
    expect([playback[@"transport"][@"position"] doubleValue]==2,"main position");
    expect([playback[@"transport"][@"subPlay"][@"position"] doubleValue]==22,"secondary independent position");
    NSString* identifier=NSUUID.UUID.UUIDString;
    expect([core addTrackWithId:identifier name:@"Nova pista" role:@"keys" error:&error],"create track while transport active");
    snapshot=[NSJSONSerialization JSONObjectWithData:[core snapshotWithError:&error] options:0 error:&error];
    NSArray* tracks=snapshot[@"project"][@"songs"][0][@"tracks"];
    expect([tracks.lastObject[@"id"] isEqual:identifier],"new track follows last track");
    expect(![core executeCommand:@"invalid" target:nil value:0 error:&error] && error!=nil,"invalid command reported");
    std::cout<<"JARAS_BRIDGE_OK\n";
}}
