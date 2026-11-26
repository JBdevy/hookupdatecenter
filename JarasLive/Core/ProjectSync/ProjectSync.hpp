#pragma once
#include "../Project/Models.hpp"
#include <cstring>
#include <cmath>
#include <stdexcept>
#include <algorithm>
#include <atomic>
#include <cctype>
namespace jaras::projectSync {
// UI/control thread only. The audio callback never reads pairing or network data.
inline std::atomic<bool> following{false};
inline thread_local unsigned internalDepth = 0;
struct Internal { Internal() { ++internalDepth; } ~Internal() { --internalDepth; } };
inline bool readOnly() { return following && internalDepth == 0; }
inline void requireWritable() { if (readOnly()) throw std::logic_error("Project Sync: PC B is controlled by PC A."); }
struct MixerTrack { ID id; double volume=1,pan=0; bool mute=false,solo=false; };
struct Mixer { double masterVolume=1,masterPan=0; bool masterMute=false,masterSolo=false; std::vector<MixerTrack> tracks; };
struct Frame { ID project; TransportState transport; std::optional<RegionSetlist> setlist; std::uint64_t revision = 0;
    bool resumeSub=false,manualSubCursor=false,autoRegionQueue=false,automaticSubplayActive=false;
    std::optional<double> playStart,subPlayStart;
    std::optional<ID> automaticSubplayQueue;
    Mixer mixer;
};
// Explicit little-endian wire format, independent of ABI, padding and CPU architecture.
// Bounded reader validates lengths before allocating; decoding never mutates the engine.
struct Writer {
    std::vector<unsigned char> bytes;
    void operator()(bool &v) { bytes.push_back(v ? 1 : 0); }
    void operator()(std::uint64_t &v) { for (int i=0;i<8;++i) bytes.push_back((unsigned char)(v >> (8*i))); }
    void operator()(int &v) { auto n=std::uint64_t(v); (*this)(n); }
    void operator()(double &v) { std::uint64_t n; std::memcpy(&n,&v,8); (*this)(n); }
    void operator()(std::string &v) { auto n=std::uint64_t(v.size()); (*this)(n); bytes.insert(bytes.end(),v.begin(),v.end()); }
    template<class T> void operator()(std::optional<T> &v) { bool exists=bool(v); (*this)(exists); if(v) (*this)(*v); }
    template<class T> void operator()(std::vector<T> &v) { auto n=std::uint64_t(v.size()); (*this)(n); for(auto &x:v) (*this)(x); }
};
struct Reader {
    const unsigned char *bytes; size_t size, offset=0;
    void need(size_t n) { if(n>size-offset) throw std::invalid_argument("Truncated Project Sync frame"); }
    void operator()(bool &v) { need(1); const auto n=bytes[offset++]; if(n>1) throw std::invalid_argument("Invalid Project Sync boolean"); v=n!=0; }
    void operator()(std::uint64_t &v) { need(8); v=0; for(int i=0;i<8;++i) v|=std::uint64_t(bytes[offset++])<<(8*i); }
    void operator()(int &v) { std::uint64_t n; (*this)(n); if(n>1000000) throw std::invalid_argument("Invalid Project Sync integer"); v=int(n); }
    void operator()(double &v) { std::uint64_t n; (*this)(n); std::memcpy(&v,&n,8); if(!std::isfinite(v)) throw std::invalid_argument("Invalid Project Sync number"); }
    void operator()(std::string &v) { std::uint64_t n; (*this)(n); if(n>1024) throw std::invalid_argument("Invalid Project Sync string"); need(size_t(n)); v.assign((const char*)bytes+offset,size_t(n)); offset+=size_t(n); }
    template<class T> void operator()(std::optional<T> &v) { bool exists; (*this)(exists); if(exists) { v.emplace(); (*this)(*v); } else v.reset(); }
    template<class T> void operator()(std::vector<T> &v) { std::uint64_t n; (*this)(n); if(n>2048) throw std::invalid_argument("Project Sync list too large"); v.resize(size_t(n)); for(auto &x:v) (*this)(x); }
};
template<class A> void archive(A &a, Frame &f, std::uint64_t version = 3) {
    a(f.project); a(f.revision);
    a(f.resumeSub);a(f.manualSubCursor);a(f.autoRegionQueue);a(f.automaticSubplayActive);
    a(f.playStart);a(f.subPlayStart);a(f.automaticSubplayQueue);
    auto &t=f.transport;
    a(t.playing); a(t.songId); a(t.position); a(t.editPosition); a(t.paused);
    a(t.regionId); a(t.queuedRegionId); a(t.queueStartedAt); a(t.queue.songId);
    a(t.loop.enabled); a(t.loop.start); a(t.loop.end); a(t.subPlay.playing); a(t.subPlay.position);
    a(t.subPlayPromotion); a(t.playbackStartRegionId); a(t.subPlaybackStartRegionId);
    a(t.ignoreNextAfter); a(t.ignoreNextEnd); a(t.ignoreNextRegionId);
    a(t.multiLoopsBypassed); a(t.queuedSectionMarkerId); a(t.sectionQueueStartedAt); a(t.sectionJumpSerial);
    bool has=bool(t.multiLoop); a(has);
    if(has) {
        if(!t.multiLoop) t.multiLoop.emplace(); auto &m=*t.multiLoop; auto &c=m.config;
        a(m.id); a(m.start); a(m.end); a(m.amount); a(m.gates); a(m.released); a(m.releasePosition);
        a(c.id); a(c.name); a(c.marker1); a(c.marker2); a(c.fadeSeconds); a(c.enabled); a(c.mixerEnabled);
        int count=int(c.tracks.size()); a(count); if(count>2048) throw std::invalid_argument("Project Sync tracks too large"); c.tracks.resize(size_t(count));
        for(auto &x:c.tracks) { a(x.id); a(x.gain); a(x.autoFader); a(x.mute); a(x.solo); }
    } else t.multiLoop.reset();
    has=bool(f.setlist); a(has);
    if(has) {
        if(!f.setlist) f.setlist.emplace(); auto &s=*f.setlist;
        a(s.selectedId); a(s.autoAdvance); a(s.stopAtRegionEnd); a(s.prepareWithoutPlayback); a(s.automaticSubplay);
        a(s.automaticSubplaySeconds); a(s.liveEnabled); a(s.playedLiveRegionIDs); a(s.autoUntilBlockEnd);
        a(s.automaticSubplayBars); a(s.automaticSubplayNext);
    } else f.setlist.reset();
    auto &m=f.mixer;
    a(m.masterVolume); a(m.masterPan); a(m.masterMute); a(m.masterSolo);
    std::uint64_t count=m.tracks.size(); a(count);
    if(count>2048) throw std::invalid_argument("Project Sync mixer too large");
    m.tracks.resize(size_t(count));
    for(auto &track:m.tracks) { a(track.id); a(track.volume); a(track.pan); a(track.mute); a(track.solo); }
    if (version >= 3) { a(t.playlistEntryId); a(t.queuedPlaylistEntryId); }
    if(version>=5) { a(t.exclusivePlaybackRegionId);a(t.subExclusivePlaybackRegionId);if(f.setlist)a(f.setlist->subplayExclusiveTrackIDs); }
}
inline std::vector<unsigned char> encode(Frame value) {
    Writer w; std::uint64_t version=(value.transport.exclusivePlaybackRegionId || value.transport.subExclusivePlaybackRegionId || (value.setlist && value.setlist->subplayExclusiveTrackIDs)) ? 5 : value.transport.automaticSectionTriggerId ? 4 : 3; w(version); archive(w,value,version);
    if(version>=4) w(value.transport.automaticSectionTriggerId);
    if(w.bytes.size()>131072) throw std::invalid_argument("Project Sync frame too large"); return w.bytes;
}
inline Frame decode(const void *data,size_t size) {
    if(size>131072) throw std::invalid_argument("Project Sync frame too large");
    Reader r{(const unsigned char*)data,size}; std::uint64_t version; r(version);
    if(version!=2 && version!=3 && version!=4 && version!=5) throw std::invalid_argument("Unsupported Project Sync version");
    Frame f; archive(r,f,version); if(version>=4) r(f.transport.automaticSectionTriggerId); if(r.offset!=size) throw std::invalid_argument("Trailing Project Sync data"); return f;
}
inline bool sameID(const ID &a,const ID &b) {
    auto normalized=[](const ID &v) { ID r; for(unsigned char c:v) if(c!='-') r.push_back(char(std::toupper(c))); return r; };
    return normalized(a)==normalized(b);
}
} // namespace jaras::projectSync
