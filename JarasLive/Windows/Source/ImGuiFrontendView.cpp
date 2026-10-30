#include "ImGuiFrontendView.h"
#include "ImGuiTimeline.h"
#include "../../WindowsNative/ThirdParty/nlohmann/json.hpp"
#include <imgui.h>
#include <algorithm>
#include <array>
#include <chrono>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <deque>
#include <map>
#include <set>
#include <utility>
#include <vector>

namespace catlive {
namespace {
using JSON = nlohmann::json;
using Clock = std::chrono::steady_clock;
const JSON& field(const JSON& value, const char* key) {
    static const JSON empty;
    if (!value.is_object()) return empty;
    const auto it = value.find(key);
    return it == value.end() ? empty : *it;
}
const JSON& array(const JSON& value) {
    static const JSON empty = JSON::array();
    return value.is_array() ? value : empty;
}
std::string string(const JSON& value, const char* key, const std::string& fallback = {}) {
    const auto& found = field(value, key);
    return found.is_string() ? found.get<std::string>() : fallback;
}
double number(const JSON& value, const char* key, double fallback = 0) {
    const auto& found = field(value, key);
    if (!found.is_number()) return fallback;
    const auto result = found.get<double>();
    return std::isfinite(result) ? result : fallback;
}
bool flag(const JSON& value, const char* key, bool fallback = false) {
    const auto& found = field(value, key);
    return found.is_boolean() ? found.get<bool>() : fallback;
}
std::string clockText(double seconds, bool hours = false) {
    const auto whole = static_cast<long long>(std::clamp(seconds, 0., 359999999.));
    char text[40];
    if (hours || whole >= 3600) std::snprintf(text, sizeof(text), "%02lld:%02lld:%02lld", whole / 3600, (whole / 60) % 60, whole % 60);
    else std::snprintf(text, sizeof(text), "%02lld:%02lld", whole / 60, whole % 60);
    return text;
}
float gainSlider(double gain) { return gain <= 0 ? 0.f : float(std::clamp((20 * std::log10(gain) + 60) / 72, 0., 1.)); }
double sliderGain(float value) { return value <= 0 ? 0 : std::pow(10., (-60 + std::clamp(value, 0.f, 1.f) * 72) / 20); }
std::string gainText(double gain) {
    if (gain <= 0) return "-inf";
    char text[32]; std::snprintf(text, sizeof(text), "%+.1f", 20 * std::log10(gain)); return text;
}
float meterFraction(double gain) { return gain <= 0 ? 0.f : float(std::clamp((20 * std::log10(gain) + 60) / 60, 0., 1.)); }
ImU32 color(const JSON& value, ImU32 fallback = IM_COL32(79, 92, 108, 255)) {
    if (!value.is_number()) return fallback;
    const auto numeric = value.get<double>();
    if (!std::isfinite(numeric) || numeric < 0 || numeric > 0xffffff) return fallback;
    const auto v = static_cast<unsigned long long>(numeric);
    return IM_COL32((v >> 16) & 255, (v >> 8) & 255, v & 255, 255);
}
void hint(const char* text) { if (ImGui::IsItemHovered(ImGuiHoveredFlags_DelayShort)) ImGui::SetTooltip("%s", text); }
bool coloredButton(const char* label, ImVec4 background, ImVec2 size = {}, bool blackText = false) {
    ImGui::PushStyleColor(ImGuiCol_Button, background);
    ImGui::PushStyleColor(ImGuiCol_ButtonHovered, ImVec4(std::min(1.f, background.x + .09f), std::min(1.f, background.y + .09f), std::min(1.f, background.z + .09f), 1));
    ImGui::PushStyleColor(ImGuiCol_ButtonActive, ImVec4(background.x * .8f, background.y * .8f, background.z * .8f, 1));
    if (blackText) ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(.04f, .04f, .04f, 1));
    const bool clicked = ImGui::Button(label, size);
    ImGui::PopStyleColor(blackText ? 4 : 3);
    return clicked;
}
enum class TransportIcon { play, stop, pause, record, previous, next, loop, click };
bool iconButton(const char* id, TransportIcon icon, ImVec4 background, float width, const char* label = nullptr) {
    const auto s = ImGui::GetFontSize() / 13.f;
    const auto p = ImGui::GetCursorScreenPos();
    const bool pressed = coloredButton(id, background, ImVec2(width * s, 29 * s));
    const auto ink = IM_COL32(10, 12, 13, ImGui::GetStyle().Alpha * 255);
    auto* draw = ImGui::GetWindowDrawList();
    const float cx = p.x + (label ? 14 : width / 2) * s, cy = p.y + 14.5f * s, d = 5 * s;
    if (icon == TransportIcon::play) draw->AddTriangleFilled(ImVec2(cx - d * .7f, cy - d), ImVec2(cx + d, cy), ImVec2(cx - d * .7f, cy + d), ink);
    else if (icon == TransportIcon::stop) draw->AddRectFilled(ImVec2(cx - d, cy - d), ImVec2(cx + d, cy + d), ink, s);
    else if (icon == TransportIcon::record) draw->AddCircleFilled(ImVec2(cx, cy), d, ink);
    else if (icon == TransportIcon::pause) {
        draw->AddRectFilled(ImVec2(cx - d, cy - d), ImVec2(cx - d / 3, cy + d), ink);
        draw->AddRectFilled(ImVec2(cx + d / 3, cy - d), ImVec2(cx + d, cy + d), ink);
    } else if (icon == TransportIcon::previous || icon == TransportIcon::next) {
        const float direction = icon == TransportIcon::next ? 1.f : -1.f;
        draw->AddTriangleFilled(ImVec2(cx - direction * d, cy - d), ImVec2(cx + direction * d * .6f, cy), ImVec2(cx - direction * d, cy + d), ink);
        draw->AddLine(ImVec2(cx + direction * d, cy - d), ImVec2(cx + direction * d, cy + d), ink, 2 * s);
    } else if (icon == TransportIcon::loop) {
        draw->AddRect(ImVec2(cx - d - s, cy - d), ImVec2(cx + d + s, cy + d), ink, 3 * s, 0, 1.5f * s);
        draw->AddTriangleFilled(ImVec2(cx + 2 * s, cy - d - 3 * s), ImVec2(cx + 5 * s, cy - d), ImVec2(cx + 2 * s, cy - d + 3 * s), ink);
    } else {
        draw->AddTriangle(ImVec2(cx, cy - 7 * s), ImVec2(cx - 6 * s, cy + 6 * s), ImVec2(cx + 6 * s, cy + 6 * s), ink, 1.5f * s);
        draw->AddLine(ImVec2(cx, cy + 3 * s), ImVec2(cx + 5 * s, cy - 5 * s), ink, 2 * s);
    }
    if (label) draw->AddText(ImVec2(p.x + 25 * s, cy - ImGui::GetFontSize() / 2), ink, label);
    return pressed;
}
std::set<std::string> idSet(const JSON& values) {
    std::set<std::string> result;
    for (const auto& value : array(values)) if (value.is_string()) result.insert(value.get<std::string>());
    return result;
}
}

struct ImGuiFrontendView::Impl {
    struct Pending { std::string action; JSON payload; Clock::time_point began; };
    struct Meter { double left = 0, right = 0, peak = 0; };
    struct Gesture { std::string track, kind; float value = 0; bool active = false; };
    struct Dialog { JSON message; bool confirm = false; };
    std::function<void(std::string)> emit;
    ImGuiTimeline timeline;
    JSON snapshot = JSON::object(), telemetry = JSON::object();
    std::map<std::uint64_t, Pending> pending;
    std::map<std::string, Meter> meters;
    std::deque<Dialog> dialogs;
    std::set<std::string> tracks, regions, items;
    std::uint64_t serial = 0;
    Clock::time_point telemetryAt = Clock::now();
    Gesture gesture;
    bool firstFrame = true, home = false, firstSnapshot = true;
    bool showTracks = true, showSetlist = true, showFooter = false, showAccount = false, addTrack = false;
    bool accountRequested = false, addRequested = false, dialogOpen = false;
    bool renameRequested = false, removeRequested = false;
    bool mediaRequested=false,acceptDrops=false;
    JSON mediaDrop;
    int mediaLayout=0;
    float mediaGap=0;
    std::string editTrack;
    std::string modalProject,modalSong;
    std::set<std::string> modalTracks;
    float displayedScroll = 0;
    std::string status, viewportKey;
    std::array<char, 320> email{};
    std::array<char, 64> cpf{};
    std::array<char, 160> device{}, trackName{};
    float mixerWidth = 276, setlistWidth = 250;
    float tempoDraft = 120;
    bool tempoEditing = false;
    bool fxOpen = false, fxLoading = false, fxDirty = false, fxCommitting = false;
    std::string fxTrack, fxName, fxSelected, fxError;
    JSON fxChain = JSON::object(), fxVerified = JSON::object();
    double lastFXPreview = 0;

    explicit Impl(std::function<void(std::string)> callback) : emit(std::move(callback)) {}
    const char* tr(const char* pt, const char* en) const { return string(snapshot, "language", "pt").rfind("en", 0) == 0 ? en : pt; }
    float scale() const { return ImGui::GetFontSize() / 13.f; }
    const JSON& project() const { return field(snapshot, "project"); }
    const JSON& song() const { return field(snapshot, "song"); }
    const JSON& transport() const { return field(telemetry, "transport").is_object() ? field(telemetry, "transport") : field(snapshot, "transport"); }
    bool editable() const { return !flag(snapshot, "busy") && !flag(snapshot, "readOnly"); }
    bool allowed() const { return flag(field(snapshot, "auth"), "allowed"); }
    bool busyAction(const std::string& action) const {
        return std::any_of(pending.begin(), pending.end(), [&](const auto& value) { return value.second.action == action; });
    }
    void error(std::string text) { status = text; dialogs.push_back({JSON{{"title", "CatLive"}, {"message", std::move(text)}}, false}); }
    void command(const std::string& action, JSON payload = JSON::object()) {
        if (!payload.is_object()) payload = JSON::object();
        if (!payload.contains("projectID") && project().is_object()) payload["projectID"] = string(project(), "id");
        if (action == "selection" || action == "selectTracks") {
            if (payload.contains("trackIDs")) tracks = idSet(payload["trackIDs"]);
            if (payload.contains("itemIDs")) items = idSet(payload["itemIDs"]);
            if (payload.contains("regionIDs")) regions = idSet(payload["regionIDs"]);
            snapshot["selection"] = {{"trackIDs", tracks}, {"itemIDs", items}, {"regionIDs", regions}};
        }
        if (!emit) { error(tr("A conexão com o CatLive não está disponível.", "The connection to CatLive is unavailable.")); return; }
        const auto id = ++serial;
        pending.emplace(id, Pending{action, payload, Clock::now()});
        emit(JSON{{"id", id}, {"action", action}, {"payload", std::move(payload)}}.dump());
    }
    void receive(const std::string& encoded) {
        auto message = JSON::parse(encoded, nullptr, false);
        if (!message.is_object()) { error(tr("Resposta inválida do CatLive.", "Invalid response from CatLive.")); return; }
        const auto type = string(message, "type");
        if(type=="fileDrop") {
            // Native messages are delivered outside a frame; hit testing uses
            // the exact timeline geometry retained by the last rendered frame.
            if(!acceptDrops||!editable()||firstSnapshot||busyAction("importMedia")||!dialogs.empty()||
               mediaRequested||mediaDrop.is_object()||showAccount||fxOpen)return;
            const auto& paths=field(message,"paths");
            if(!paths.is_array()||paths.empty()||paths.size()>1024)return;
            for(const auto& path:paths)if(!path.is_string()||path.get_ref<const std::string&>().empty())return;
            auto projectFile=[](const JSON& path){auto name=path.get<std::string>();
                std::transform(name.begin(),name.end(),name.begin(),[](unsigned char c){return char(std::tolower(c));});
                return name.size()>=3&&name.substr(name.size()-3)==".jl";};
            if(std::any_of(paths.begin(),paths.end(),projectFile)) {
                if(paths.size()==1)command("open",{{"path",paths.front()}});
                else error(tr("Abra um projeto por vez.","Open one project at a time."));
                return;
            }
            if(home)return;
            auto destination=timeline.mediaDropTarget(snapshot,float(number(message,"x",-1)),float(number(message,"y",-1)),flag(message,"shift"));
            if(!destination.is_object())return;
            destination["paths"]=paths;
            if(paths.size()==1){destination["layout"]="separateTracks";destination["gap"]=0;command("importMedia",std::move(destination));}
            else {mediaDrop=std::move(destination);mediaRequested=true;mediaLayout=0;mediaGap=0;acceptDrops=false;}
            return;
        }
        if (type == "reply") {
            const auto& idValue = field(message, "id");
            if (idValue.is_number_unsigned() || (idValue.is_number_integer() && idValue.get<long long>() >= 0)) {
                const auto found = pending.find(idValue.get<std::uint64_t>());
                if (found != pending.end()) {
                    const auto call = std::move(found->second); pending.erase(found);
                    if (call.payload.contains("requestId")) message["requestId"] = call.payload["requestId"];
                    const bool ok = flag(message, "ok");
                    const bool currentFX = string(call.payload, "projectID") == string(project(), "id") && string(call.payload, "trackID") == fxTrack;
                    if (!ok) {
                        const auto detail = string(message, "error", "CatLive");
                        if (currentFX && call.action.rfind("effects", 0) == 0) {
                            fxError = detail;
                            if (call.action == "effectsGet" || call.action == "effectsChooseSample") fxLoading = false;
                            if (call.action == "effectsCommit") { fxChain = fxVerified; fxDirty = false; fxCommitting = false; }
                        }
                        if (detail != "Canceled" && call.action != "waveform") error(detail);
                        else if (detail == "Canceled") status = tr("Operação cancelada.", "Operation canceled.");
                    } else if ((call.action == "effectsGet" || call.action == "effectsChooseSample") &&
                               currentFX && fxOpen) {
                        fxChain = field(field(message, "result"), "settings");
                        if (!fxChain.is_object()) fxChain = JSON::object();
                        fxVerified = fxChain; fxLoading = false; fxDirty = false;
                        const auto& inserted = array(field(fxChain, "inserted"));
                        if (std::find(inserted.begin(), inserted.end(), fxSelected) == inserted.end())
                            fxSelected = inserted.empty() ? std::string() : inserted.front().get<std::string>();
                    } else if (call.action == "effectsCommit" && currentFX) {
                        fxVerified = field(call.payload, "settings"); fxCommitting = false;
                    } else if (call.action == "open" || call.action == "new") { home = false; status.clear(); }
                    else if (call.action == "save") status = tr("Projeto salvo.", "Project saved.");
                }
            }
        } else if (type == "snapshot") {
            const bool changed = string(field(message, "project"), "id") != string(project(), "id") ||
                                 string(field(message, "song"), "id") != string(song(), "id");
            if (changed) { gesture = {}; viewportKey.clear(); meters.clear(); fxOpen = false; fxDirty = false; fxLoading = false; fxCommitting = false; telemetry = JSON::object();
                renameRequested=removeRequested=addRequested=addTrack=mediaRequested=false;editTrack.clear();modalTracks.clear();mediaDrop=JSON();acceptDrops=false; }
            snapshot = message;
            if(flag(snapshot,"busy")){mediaDrop=JSON();mediaRequested=false;acceptDrops=false;}
            const auto& selection = field(message, "selection");
            tracks = idSet(field(selection, "trackIDs")); items = idSet(field(selection, "itemIDs")); regions = idSet(field(selection, "regionIDs"));
            if (changed || !telemetry.contains("transport")) { telemetry["transport"] = field(snapshot, "transport"); telemetryAt = Clock::now(); }
            if (firstSnapshot) {
                home = array(field(song(), "tracks")).empty() && array(field(song(), "parts")).empty() && string(field(snapshot, "document"), "path").empty();
                firstSnapshot = false;
            }
            if (!string(message, "status").empty()) status = string(message, "status");
        } else if (type == "telemetry") {
            if (!string(message, "projectID").empty() && string(message, "projectID") != string(project(), "id")) return;
            telemetry = message; telemetryAt = Clock::now();
            meters.clear();
            for (const auto& entry : array(field(message, "meters")))
                meters.emplace(string(entry, "trackID"), Meter{number(entry, "left"), number(entry, "right"), number(entry, "peak")});
        } else if (type == "notice" || type == "confirm") {
            // A backend notice owns the modal level. Abandon staged imports
            // rather than leaving an invisible payload that blocks later drops.
            mediaDrop=JSON();mediaRequested=false;acceptDrops=false;
            status = string(message, "message"); dialogs.push_back({message, type == "confirm"});
        }
        timeline.receive(message);
    }
    void mixer(const std::string& kind, const std::string& track, double value, const char* phase = "change") {
        const auto targets = track.empty() ? std::set<std::string>{} : tracks.count(track) ? tracks : std::set<std::string>{track};
        command("mixer", {{"kind", kind}, {"trackID", track}, {"value", value}, {"targets", targets}, {"phase", phase}});
    }
    void slider(const char* label, const std::string& kind, const std::string& track, double actual, float width, bool pan = false) {
        const bool held = gesture.active && gesture.track == track && gesture.kind == kind;
        float value = held ? gesture.value : pan ? float(actual) : gainSlider(actual);
        ImGui::SetNextItemWidth(width);
        const bool changed = ImGui::SliderFloat(label, &value, pan ? -1.f : 0.f, 1.f, "", ImGuiSliderFlags_NoInput);
        if (ImGui::IsItemActivated()) { gesture = {track, kind, value, true}; mixer(kind, track, pan ? value : sliderGain(value), "begin"); }
        if (changed) { gesture = {track, kind, value, true}; mixer(kind, track, pan ? value : sliderGain(value)); }
        if (ImGui::IsItemDeactivated() && gesture.active && gesture.track == track && gesture.kind == kind) {
            mixer(kind, track, pan ? value : sliderGain(value), "end"); gesture = {};
        }
        if (ImGui::IsItemHovered()) ImGui::SetTooltip("%s", pan ? (std::to_string(int(value * 100)) + "%").c_str() : (gainText(sliderGain(value)) + " dB").c_str());
    }
    void meter(const std::string& track, ImVec2 size) {
        const auto found = meters.find(track);
        const auto value = found == meters.end() ? Meter{} : found->second;
        const auto p = ImGui::GetCursorScreenPos();
        ImGui::InvisibleButton("##meter", size);
        auto* draw = ImGui::GetWindowDrawList();
        const float gap = std::max(1.f, scale()), width = (size.x - gap) / 2;
        for (int channel = 0; channel < 2; ++channel) {
            const float x = p.x + channel * (width + gap), fraction = meterFraction(channel ? value.right : value.left);
            draw->AddRectFilled(ImVec2(x, p.y), ImVec2(x + width, p.y + size.y), IM_COL32(14, 18, 23, 255), 1);
            draw->AddRectFilled(ImVec2(x, p.y + size.y * (1 - fraction)), ImVec2(x + width, p.y + size.y), IM_COL32(59, 163, 244, 255), 1);
            if (value.peak >= 1) draw->AddRectFilled(ImVec2(x, p.y), ImVec2(x + width, p.y + 3 * scale()), IM_COL32(255, 62, 69, 255));
        }
        if (ImGui::IsItemClicked()) command("clearPeak", {{"trackID", track}});
        if (ImGui::IsItemHovered()) ImGui::SetTooltip("Peak %s dB\n%s", gainText(value.peak).c_str(), tr("Clique para limpar", "Click to reset"));
    }
    void openFX(const std::string& track, const std::string& name) {
        if (fxDirty || fxCommitting) { error(tr("Aplique ou descarte os ajustes de efeitos antes de trocar a pista.", "Apply or discard the effect changes before switching tracks.")); return; }
        fxTrack = track; fxName = name; fxOpen = true; fxLoading = true; fxSelected.clear(); fxError.clear();
        command("effectsGet", {{"trackID", track}});
    }
    void masterStrip(float width, float height) {
        ImGui::BeginChild("##master", ImVec2(width, height), ImGuiChildFlags_Borders, ImGuiWindowFlags_NoScrollbar);
        meter("", ImVec2(12 * scale(), height - 18 * scale())); ImGui::SameLine();
        ImGui::BeginGroup(); ImGui::TextUnformatted("MASTER"); ImGui::SameLine();
        if (ImGui::SmallButton("FX")) openFX("", "Master");
        const auto gain = gesture.active && gesture.track.empty() && gesture.kind == "masterVolume" ? sliderGain(gesture.value) : number(project(), "masterVolume", 1);
        ImGui::SameLine(); ImGui::TextDisabled("%s dB", gainText(gain).c_str());
        ImGui::BeginDisabled(!editable()); slider("##masterGain", "masterVolume", "", number(project(), "masterVolume", 1), std::max(40.f, width - 42 * scale())); ImGui::EndDisabled();
        const auto found = meters.find("");
        ImGui::TextDisabled("Peak %s dB", gainText(found == meters.end() ? 0 : found->second.peak).c_str());
        ImGui::EndGroup(); ImGui::EndChild();
    }
    void toolbar() {
        const auto s = scale();
        ImGui::BeginChild("##toolbar", ImVec2(0, 85 * s), ImGuiChildFlags_None, ImGuiWindowFlags_NoScrollbar);
        masterStrip(230 * s, 78 * s); ImGui::SameLine();
        ImGui::BeginGroup();
        ImGui::BeginDisabled(!editable());
        if (ImGui::Button(tr("Arquivo", "File"))) ImGui::OpenPopup("##fileMenu");
        if (ImGui::BeginPopup("##fileMenu")) {
            if (ImGui::MenuItem(tr("Novo projeto...", "New project..."))) command("new");
            if (ImGui::MenuItem(tr("Abrir projeto...", "Open project..."), "Ctrl+O")) command("open");
            if (ImGui::MenuItem(tr("Salvar", "Save"), "Ctrl+S")) command("save");
            ImGui::EndPopup();
        }
        ImGui::SameLine();
        if (ImGui::Button(flag(snapshot, "dirty") ? tr("Salvar *", "Save *") : tr("Salvar", "Save"))) command("save"); hint("Ctrl+S"); ImGui::SameLine();
        ImGui::BeginDisabled(!flag(snapshot, "canUndo")); if (ImGui::Button("Undo")) command("undo"); ImGui::EndDisabled(); ImGui::SameLine();
        ImGui::BeginDisabled(!flag(snapshot, "canRedo")); if (ImGui::Button("Redo")) command("redo"); ImGui::EndDisabled();
        ImGui::EndDisabled(); ImGui::SameLine();
        if (ImGui::Button(tr("Conta", "Account"))) accountRequested = true;
        ImGui::SameLine(); if (ImGui::Button("Home")) home = !home;
        ImGui::SameLine(); if (ImGui::Button("Tracks")) showTracks = !showTracks;
        ImGui::SameLine(); if (ImGui::Button("Setlist")) showSetlist = !showSetlist;
        ImGui::SameLine(); if (ImGui::Button("Mixer")) showFooter = !showFooter;
        ImGui::Spacing();
        const bool playing = flag(transport(), "playing"), paused = flag(transport(), "paused");
        ImGui::BeginDisabled(!editable());
        if (iconButton("##previous", TransportIcon::previous, ImVec4(.47f, .49f, .51f, 1), 25)) command("transport", {{"kind", "previous"}});
        hint(tr("Região anterior", "Previous region")); ImGui::SameLine();
        if (iconButton("##playStop", playing ? TransportIcon::stop : TransportIcon::play, playing ? ImVec4(1, .23f, .25f, 1) : ImVec4(.16f, .93f, .39f, 1), 65, playing ? "Stop" : "Play")) command(playing ? "stop" : "play");
        hint(tr("Reproduzir / parar", "Play / stop")); ImGui::SameLine();
        if (iconButton("##pause", TransportIcon::pause, paused ? ImVec4(.62f, .62f, .62f, 1) : ImVec4(.36f, .36f, .36f, 1), 29)) command("pause");
        hint(tr("Pausar", "Pause")); ImGui::SameLine();
        if (iconButton("##subPlay", flag(transport(), "subPlaying") ? TransportIcon::stop : TransportIcon::play, ImVec4(.96f, .85f, .14f, 1), 29)) command("transport", {{"kind", flag(transport(), "subPlaying") ? "subStop" : "subPlay"}});
        hint("Sub Play"); ImGui::SameLine();
        if (iconButton("##record", TransportIcon::record, flag(transport(), "recording") ? ImVec4(1, .2f, .23f, 1) : ImVec4(.65f, .29f, .30f, 1), 29)) command("record");
        hint(tr("Gravar", "Record")); ImGui::SameLine();
        if (iconButton("##next", TransportIcon::next, ImVec4(.47f, .49f, .51f, 1), 25)) command("transport", {{"kind", "next"}});
        hint(tr("Próxima região", "Next region")); ImGui::SameLine();
        if (iconButton("##loop", TransportIcon::loop, flag(transport(), "loop") ? ImVec4(.3f, .78f, .44f, 1) : ImVec4(.47f, .49f, .51f, 1), 27)) command("transport", {{"kind", "toggleLoop"}});
        hint("Loop"); ImGui::SameLine();
        if (iconButton("##click", TransportIcon::click, flag(transport(), "metronome") ? ImVec4(.3f, .78f, .44f, 1) : ImVec4(.47f, .49f, .51f, 1), 27)) command("metronome", {{"enabled", !flag(transport(), "metronome")}});
        hint(tr("Metrônomo", "Metronome"));
        ImGui::EndDisabled(); ImGui::SameLine();
        const auto elapsed = std::chrono::duration<double>(Clock::now() - telemetryAt).count();
        const auto visual = number(transport(), "position") + (playing ? std::clamp(elapsed, 0., .1) : 0.);
        ImGui::AlignTextToFramePadding(); ImGui::Text("%s", clockText(visual, true).c_str()); ImGui::SameLine();
        float bpm = tempoEditing ? tempoDraft : float(number(transport(), "bpm", 120));
        ImGui::BeginDisabled(!editable()); ImGui::SetNextItemWidth(65 * s);
        ImGui::DragFloat("##tempo", &bpm, .1f, 20.f, 400.f, "%.1f BPM");
        tempoEditing = ImGui::IsItemActive(); tempoDraft = bpm;
        if (ImGui::IsItemDeactivatedAfterEdit()) command("tempo", {{"value", bpm}});
        ImGui::EndDisabled(); ImGui::SameLine();
        ImGui::TextDisabled("%d/%d", int(number(transport(), "beats", 4)), int(number(transport(), "unit", 4)));
        if (flag(transport(), "recording")) { ImGui::SameLine(); ImGui::TextColored(ImVec4(1, .2f, .23f, 1), "REC"); }
        if (!allowed()) { ImGui::SameLine(); ImGui::TextDisabled("%s", tr("Login necessário", "Sign in required")); }
        ImGui::EndGroup(); ImGui::EndChild();
    }
    void trackRow(const JSON& track, int index, float width, bool footer) {
        const auto id = string(track, "id");
        const auto s = scale();
        ImGui::PushID(id.c_str());
        const auto selected = tracks.count(id) != 0;
        ImGui::PushStyleColor(ImGuiCol_ChildBg, selected ? ImVec4(.16f, .19f, .21f, 1) : ImVec4(.12f, .13f, .14f, 1));
        ImGui::BeginChild("##strip", ImVec2(width, footer ? 155 * s : ImGuiTimeline::trackHeight(track)), ImGuiChildFlags_Borders, ImGuiWindowFlags_NoScrollbar);
        const auto p = ImGui::GetWindowPos(), sz = ImGui::GetWindowSize();
        ImGui::GetWindowDrawList()->AddRectFilled(p, ImVec2(p.x + 3 * s, p.y + sz.y), color(field(track, "color")));
        if (selected) ImGui::GetWindowDrawList()->AddRect(p, ImVec2(p.x + sz.x, p.y + sz.y), IM_COL32(143, 211, 255, 255), 3);
        const auto title = std::to_string(index + 1) + "  " + string(track, "name", "Audio");
        if (ImGui::Selectable((title + "##select").c_str(), false, ImGuiSelectableFlags_None, ImVec2(std::max(20.f, width - 22 * s), 17 * s))) {
            if (ImGui::GetIO().KeyCtrl) { if (tracks.count(id)) tracks.erase(id); else tracks.insert(id); } else tracks = {id};
            command("selectTracks", {{"trackIDs", tracks}});
        }
        if (ImGui::BeginPopupContextItem("##trackMenu")) {
            ImGui::BeginDisabled(!editable());
            if (ImGui::MenuItem(tr("Renomear pista", "Rename track"))) {
                editTrack = id; std::snprintf(trackName.data(), trackName.size(), "%s", string(track, "name").c_str()); renameRequested = true;
            }
            if (ImGui::MenuItem(tr("Excluir pistas selecionadas", "Delete selected tracks"))) { if (!tracks.count(id)) tracks = {id}; removeRequested = true; }
            ImGui::EndDisabled(); ImGui::EndPopup();
        }
        ImGui::BeginDisabled(!editable());
        const auto& arms = field(snapshot, "recordArms");
        const int armMode = int(number(arms, id.c_str(), flag(arms, id.c_str()) ? 1 : 0));
        const bool armed = flag(field(snapshot, "recordArmed"), id.c_str(), armMode == 1 || (armMode == 2 && selected));
        if (coloredButton(armMode == 2 ? "A" : "R", armed ? ImVec4(.94f, .22f, .25f, 1) : ImVec4(.25f, .26f, .27f, 1), ImVec2(21 * s, 20 * s), armed)) command("recordArm", {{"trackID", id}});
        hint(armMode == 2 ? tr("Gravar quando selecionada", "Record when selected") : tr("Armar gravação", "Arm recording")); ImGui::SameLine(0, 3 * s);
        if (coloredButton("M", flag(track, "mute") ? ImVec4(.94f, .22f, .25f, 1) : ImVec4(.25f, .26f, .27f, 1), ImVec2(23 * s, 20 * s), flag(track, "mute"))) mixer("mute", id, !flag(track, "mute"));
        ImGui::SameLine(0, 3 * s);
        if (coloredButton("S", flag(track, "solo") ? ImVec4(1, .85f, .12f, 1) : ImVec4(.25f, .26f, .27f, 1), ImVec2(23 * s, 20 * s), flag(track, "solo"))) mixer("solo", id, !flag(track, "solo"));
        ImGui::SameLine(0, 3 * s);
        if (coloredButton("Pol", flag(track, "phaseInverted") ? ImVec4(.2f, .55f, .78f, 1) : ImVec4(.25f, .26f, .27f, 1), ImVec2(29 * s, 20 * s))) mixer("phase", id, !flag(track, "phaseInverted"));
        hint(tr("Inverter polaridade", "Invert polarity"));
        if (!footer) { ImGui::SameLine(0, 3 * s); slider("##pan", "pan", id, number(track, "pan"), std::max(32.f, width - 168 * s), true); }
        ImGui::SameLine(0, 3 * s); if (ImGui::Button("FX", ImVec2(25 * s, 20 * s))) openFX(id, string(track, "name"));
        if (footer) { meter(id, ImVec2(12 * s, 67 * s)); ImGui::SameLine(); ImGui::BeginGroup(); }
        slider("##gain", "volume", id, number(track, "volume", 1), std::max(30.f, width - (footer ? 40 : 76) * s));
        if (!footer) ImGui::SameLine();
        const auto gain = gesture.active && gesture.track == id && gesture.kind == "volume" ? sliderGain(gesture.value) : number(track, "volume", 1);
        ImGui::TextDisabled("%s", gainText(gain).c_str());
        if (footer) { slider("##panFooter", "pan", id, number(track, "pan"), width - 40 * s, true); ImGui::EndGroup(); }
        ImGui::EndDisabled();
        if (!footer) {
            const auto m = meters.find(id); const auto levels = m == meters.end() ? Meter{} : m->second;
            const auto x = p.x + 6 * s, y = p.y + sz.y - 5 * s, available = sz.x - 12 * s;
            auto* draw = ImGui::GetWindowDrawList();
            draw->AddRectFilled(ImVec2(x, y), ImVec2(x + available, y + 2 * s), IM_COL32(15, 20, 25, 255));
            draw->AddRectFilled(ImVec2(x, y), ImVec2(x + available * meterFraction(std::max(levels.left, levels.right)), y + 2 * s), IM_COL32(59, 163, 244, 255));
        }
        ImGui::EndChild(); ImGui::PopStyleColor(); ImGui::PopID();
    }
    void trackPanel(float height, std::set<std::string>& visible) {
        const auto s = scale();
        ImGui::BeginChild("##tracksPanel", ImVec2(mixerWidth * s, height), ImGuiChildFlags_Borders);
        const auto headerTop = ImGui::GetCursorPosY();
        ImGui::TextDisabled("TRACK MIXER"); ImGui::SameLine();
        ImGui::BeginDisabled(!editable()); if (ImGui::SmallButton("+")) addRequested = true; ImGui::EndDisabled();
        ImGui::Separator();
        ImGui::SetCursorPosY(headerTop + timeline.headerHeight(snapshot));
        ImGui::BeginChild("##trackScroll", ImVec2(0, 0));
        if (std::abs(displayedScroll - timeline.verticalOffset()) > .5f) ImGui::SetScrollY(timeline.verticalOffset());
        const auto& all = array(field(song(), "tracks"));
        ImGui::PushStyleVar(ImGuiStyleVar_ItemSpacing, ImVec2(0, 0));
        int index = 0;
        for (const auto& track : all) {
            const auto rowHeight = ImGuiTimeline::trackHeight(track);
            if (ImGui::IsRectVisible(ImVec2(ImGui::GetContentRegionAvail().x, rowHeight))) {
                visible.insert(string(track, "id")); trackRow(track, index, ImGui::GetContentRegionAvail().x, false);
            } else ImGui::Dummy(ImVec2(1, rowHeight));
            ++index;
        }
        ImGui::PopStyleVar();
        if (all.empty()) ImGui::TextDisabled("%s", tr("Adicione uma pista para começar.", "Add a track to get started."));
        displayedScroll = ImGui::GetScrollY();
        if (ImGui::IsWindowHovered(ImGuiHoveredFlags_ChildWindows)) timeline.setVerticalOffset(displayedScroll);
        ImGui::EndChild(); ImGui::EndChild();
    }
    std::vector<std::pair<std::string, const JSON*>> playlistRows() const {
        std::vector<std::pair<std::string, const JSON*>> rows;
        const auto& parts = array(field(song(), "parts"));
        const auto& setlist = field(project(), "regionSetlist");
        const auto selected = string(setlist, "selectedId");
        for (const auto& playlist : array(field(setlist, "playlists"))) if (string(playlist, "id") == selected && string(playlist, "songId") == string(song(), "id")) {
            for (const auto& entry : array(field(playlist, "regionIds"))) if (entry.is_string()) {
                const auto entryID = entry.get<std::string>(); auto region = entryID;
                for (const auto& duplicate : array(field(playlist, "duplicates"))) if (string(duplicate, "id") == entryID) region = string(duplicate, "regionId");
                for (const auto& part : parts) if (string(part, "id") == region) { rows.emplace_back(entryID, &part); break; }
            }
            return rows;
        }
        for (const auto& part : parts) if (string(part, "parentRegionID").empty()) rows.emplace_back(string(part, "id"), &part);
        return rows;
    }
    void regionButton(const JSON& part, const std::string& entryID, bool child = false) {
        const auto id = string(part, "id");
        const bool selected = regions.count(entryID) || string(transport(), "selectedRegionID") == id;
        const bool playing = flag(transport(), "playing") && string(transport(), "regionID", string(transport(), "selectedRegionID")) == id;
        ImGui::PushID(entryID.c_str());
        const auto p = ImGui::GetCursorScreenPos(); const float w = ImGui::GetContentRegionAvail().x;
        const auto title = string(part, "name", tr("Região", "Region"));
        if (ImGui::Selectable("##region", selected, ImGuiSelectableFlags_None, ImVec2(w, (child ? 34 : 49) * scale()))) {
            regions = {entryID}; command("selectRegion", {{"regionID", id}, {"entryID", entryID}});
            snapshot["selection"]["regionIDs"] = regions;
        }
        if (ImGui::BeginPopupContextItem("##regionMenu")) {
            ImGui::BeginDisabled(!editable());
            if (ImGui::MenuItem(tr("Preparar próxima região", "Queue region"))) command("transport", {{"kind", "queueRegion"}, {"target", entryID}});
            if (ImGui::MenuItem(tr("Reproduzir daqui", "Play from here"))) { command("selectRegion", {{"regionID", id}, {"entryID", entryID}}); command("play"); }
            ImGui::EndDisabled(); ImGui::EndPopup();
        }
        auto* draw = ImGui::GetWindowDrawList();
        draw->AddRectFilled(p, ImVec2(p.x + 3 * scale(), p.y + (child ? 30 : 45) * scale()), color(field(part, "color")));
        const auto textColor = playing ? IM_COL32(85, 244, 131, 255) : IM_COL32(231, 233, 236, 255);
        draw->PushClipRect(p, ImVec2(p.x + w, p.y + 49 * scale()), true);
        draw->AddText(ImVec2(p.x + 10 * scale(), p.y + 3 * scale()), textColor, title.c_str());
        const auto details = clockText(number(part, "startTime"), true) + "    " + clockText(number(part, "endTime") - number(part, "startTime"));
        draw->AddText(ImVec2(p.x + 10 * scale(), p.y + 21 * scale()), IM_COL32(151, 158, 168, 255), details.c_str());
        draw->PopClipRect();
        ImGui::PopID();
    }
    void setlistPanel(float height) {
        ImGui::BeginChild("##setlist", ImVec2(setlistWidth * scale(), height), ImGuiChildFlags_Borders);
        ImGui::TextDisabled("SETLIST");
        const auto& state = field(project(), "regionSetlist"); const auto selected = string(state, "selectedId");
        auto title = std::string(tr("Todas as regiões", "All regions"));
        for (const auto& playlist : array(field(state, "playlists"))) if (string(playlist, "id") == selected) title = string(playlist, "name");
        ImGui::SetNextItemWidth(-1);
        ImGui::BeginDisabled(!editable());
        if (ImGui::BeginCombo("##playlist", title.c_str())) {
            if (ImGui::Selectable(tr("Todas as regiões", "All regions"), selected.empty())) command("choosePlaylist", {{"playlistID", ""}});
            for (const auto& playlist : array(field(state, "playlists"))) if (string(playlist, "songId") == string(song(), "id")) {
                const auto id = string(playlist, "id");
                if (ImGui::Selectable((string(playlist, "name") + "##" + id).c_str(), id == selected)) command("choosePlaylist", {{"playlistID", id}});
            }
            ImGui::EndCombo();
        }
        ImGui::EndDisabled();
        const auto rows = playlistRows(); double duration = 0;
        ImGui::BeginChild("##regionRows", ImVec2(0, -26 * scale()));
        for (const auto& row : rows) {
            regionButton(*row.second, row.first); duration += std::max(0., number(*row.second, "endTime") - number(*row.second, "startTime"));
            if (regions.count(row.first) || string(transport(), "selectedRegionID") == string(*row.second, "id")) {
                for (const auto& part : array(field(song(), "parts"))) if (string(part, "parentRegionID") == string(*row.second, "id")) {
                    ImGui::Indent(12 * scale()); regionButton(part, string(part, "id"), true); ImGui::Unindent(12 * scale());
                }
            }
        }
        if (rows.empty()) ImGui::TextDisabled("%s", tr("Nenhuma região neste projeto.", "No regions in this project."));
        ImGui::EndChild(); ImGui::Separator();
        ImGui::Text("%zu   %s", rows.size(), clockText(duration, true).c_str());
        ImGui::EndChild();
    }
    void footerMixer(std::set<std::string>& visible) {
        ImGui::BeginChild("##footerMixer", ImVec2(0, 181 * scale()), ImGuiChildFlags_Borders, ImGuiWindowFlags_HorizontalScrollbar);
        int index = 0;
        for (const auto& track : array(field(song(), "tracks"))) {
            if (index) ImGui::SameLine();
            if (ImGui::IsRectVisible(ImVec2(168 * scale(), 155 * scale()))) visible.insert(string(track, "id"));
            trackRow(track, index++, 168 * scale(), true);
        }
        ImGui::EndChild();
    }
    void homePanel() {
        const auto available = ImGui::GetContentRegionAvail(); const auto s = scale();
        ImGui::SetCursorPosX(ImGui::GetCursorPosX() + std::max(0.f, (available.x - 440 * s) / 2));
        ImGui::SetCursorPosY(ImGui::GetCursorPosY() + std::max(0.f, (available.y - 260 * s) / 3));
        ImGui::BeginChild("##homeCard", ImVec2(std::min(440 * s, available.x), std::min(300 * s, available.y)), ImGuiChildFlags_Borders);
        ImGui::TextUnformatted("CatLive"); ImGui::Spacing();
        ImGui::TextWrapped("%s", tr("Seu palco. Seu projeto.", "Your stage. Your project.")); ImGui::Spacing();
        ImGui::BeginDisabled(!editable());
        if (coloredButton(tr("Abrir projeto...", "Open project..."), ImVec4(.17f, .76f, .36f, 1), ImVec2(-1, 36 * s), true)) command("open");
        if (ImGui::Button(tr("Novo projeto...", "New project..."), ImVec2(-1, 32 * s))) command("new");
        ImGui::EndDisabled();
        if (ImGui::Button(tr("Continuar no projeto atual", "Continue current project"), ImVec2(-1, 32 * s))) home = false;
        ImGui::TextWrapped("%s", string(project(), "name", "CatLive").c_str());
        const auto& auth = field(snapshot, "auth");
        ImGui::Spacing(); ImGui::TextWrapped("%s", string(auth, "message", string(auth, "title")).c_str());
        if (ImGui::Button(allowed() ? tr("Minha conta", "My account") : tr("Entrar", "Sign in"), ImVec2(-1, 32 * s))) accountRequested = true;
        ImGui::EndChild();
    }
    void modalPanels() {
        const auto s = scale();
        if (accountRequested) { ImGui::OpenPopup("##account"); showAccount = true; accountRequested = false; }
        ImGui::SetNextWindowSize(ImVec2(420 * s, 0), ImGuiCond_Appearing);
        if (ImGui::BeginPopupModal("##account", &showAccount, ImGuiWindowFlags_AlwaysAutoResize)) {
            const auto& auth = field(snapshot, "auth");
            ImGui::TextUnformatted("CatLive"); ImGui::Spacing();
            ImGui::TextWrapped("%s", string(auth, "message", string(auth, "title")).c_str());
            const bool naming = flag(auth, "requiresDeviceName"), signedIn = flag(auth, "allowed");
            const bool pendingAuth = flag(auth, "busy") || busyAction("login") || busyAction("deviceName") || busyAction("logout");
            ImGui::BeginDisabled(pendingAuth);
            ImGui::SetNextItemWidth(-1);
            if (naming) ImGui::InputText(tr("Nome do dispositivo", "Device name"), device.data(), device.size());
            else if (!signedIn) {
                ImGui::InputText("E-mail", email.data(), email.size());
                ImGui::SetNextItemWidth(-1); ImGui::InputText("CPF", cpf.data(), cpf.size());
            }
            if (!signedIn) {
                const bool valid = naming ? device[0] != 0 : email[0] != 0 && cpf[0] != 0;
                ImGui::BeginDisabled(!valid);
                if (ImGui::Button(naming ? tr("Salvar nome", "Save name") : tr("Entrar", "Sign in"), ImVec2(-1, 30 * s))) {
                    if (naming) command("deviceName", {{"name", device.data()}});
                    else command("login", {{"email", email.data()}, {"cpf", cpf.data()}});
                }
                ImGui::EndDisabled();
            } else {
                ImGui::BeginDisabled(flag(transport(), "playing") || flag(transport(), "recording"));
                if (ImGui::Button(tr("Sair da conta", "Sign out"), ImVec2(-1, 30 * s))) command("logout");
                ImGui::EndDisabled();
            }
            ImGui::EndDisabled();
            if (pendingAuth) ImGui::TextDisabled("%s", tr("Aguarde...", "Please wait..."));
            if (ImGui::Button(tr("Fechar", "Close"), ImVec2(-1, 28 * s))) { showAccount = false; ImGui::CloseCurrentPopup(); }
            ImGui::EndPopup();
        }
        const auto captureDocument=[&]{modalProject=string(project(),"id");modalSong=string(song(),"id");};
        const auto staleDocument=[&]{return modalProject!=string(project(),"id")||modalSong!=string(song(),"id");};
        if(mediaRequested){ImGui::OpenPopup("##importMedia");mediaRequested=false;}
        ImGui::SetNextWindowSize(ImVec2(440*s,0),ImGuiCond_Appearing);
        if(ImGui::BeginPopupModal("##importMedia",nullptr,ImGuiWindowFlags_AlwaysAutoResize)) {
            if(!mediaDrop.is_object()||string(mediaDrop,"projectID")!=string(project(),"id")||string(mediaDrop,"songID")!=string(song(),"id")) {
                mediaDrop=JSON();ImGui::CloseCurrentPopup();ImGui::EndPopup();return;
            }
            ImGui::TextUnformatted(tr("Importar mídia","Import media"));ImGui::Separator();
            ImGui::RadioButton(tr("Uma pista por item","One track per item"),&mediaLayout,0);
            ImGui::RadioButton(tr("Na mesma pista, em sequência","On the same track, in sequence"),&mediaLayout,1);
            ImGui::RadioButton(tr("Na mesma pista, iniciando juntos","On the same track, starting together"),&mediaLayout,2);
            if(mediaLayout==1)ImGui::InputFloat(tr("Intervalo (s)","Gap (s)"),&mediaGap,0,0,"%.3f");
            const bool validGap=mediaLayout!=1||(std::isfinite(mediaGap)&&mediaGap>=0&&mediaGap<=60);
            if(!validGap)ImGui::TextWrapped("%s",tr("Informe um intervalo de 0 a 60 segundos.","Enter a gap from 0 to 60 seconds."));
            if(ImGui::Button(tr("Cancelar","Cancel"))){mediaDrop=JSON();ImGui::CloseCurrentPopup();}
            ImGui::SameLine();ImGui::BeginDisabled(!validGap||!editable()||!mediaDrop.is_object());
            if(coloredButton(tr("Importar","Import"),ImVec4(.36f,.76f,.27f,1),{},true)) {
                mediaDrop["layout"]=mediaLayout==1?"sameTrack":mediaLayout==2?"stacked":"separateTracks";
                mediaDrop["gap"]=mediaLayout==1?mediaGap:0;command("importMedia",mediaDrop);mediaDrop=JSON();ImGui::CloseCurrentPopup();
            }
            ImGui::EndDisabled();ImGui::EndPopup();
        }
        if (addRequested) { captureDocument();ImGui::OpenPopup("##addTrack"); addTrack = true; std::snprintf(trackName.data(), trackName.size(), "Audio"); addRequested = false; }
        if (ImGui::BeginPopupModal("##addTrack", &addTrack, ImGuiWindowFlags_AlwaysAutoResize)) {
            if(staleDocument()){ImGui::CloseCurrentPopup();ImGui::EndPopup();return;}
            ImGui::TextUnformatted(tr("Adicionar pista", "Add track"));
            const bool enter = ImGui::InputText(tr("Nome", "Name"), trackName.data(), trackName.size(), ImGuiInputTextFlags_EnterReturnsTrue);
            ImGui::BeginDisabled(!trackName[0]);
            if (ImGui::Button(tr("Adicionar", "Add")) || (enter && trackName[0])) { command("addTrack", {{"name", trackName.data()}}); addTrack = false; ImGui::CloseCurrentPopup(); }
            ImGui::EndDisabled(); ImGui::SameLine();
            if (ImGui::Button(tr("Cancelar", "Cancel"))) { addTrack = false; ImGui::CloseCurrentPopup(); }
            ImGui::EndPopup();
        }
        if (renameRequested) {captureDocument();ImGui::OpenPopup("##renameTrack"); renameRequested = false; }
        if (ImGui::BeginPopupModal("##renameTrack", nullptr, ImGuiWindowFlags_AlwaysAutoResize)) {
            if(staleDocument()){ImGui::CloseCurrentPopup();ImGui::EndPopup();return;}
            ImGui::TextUnformatted(tr("Renomear pista", "Rename track"));
            const bool enter = ImGui::InputText(tr("Nome", "Name"), trackName.data(), trackName.size(), ImGuiInputTextFlags_EnterReturnsTrue);
            ImGui::BeginDisabled(!trackName[0]);
            if (ImGui::Button(tr("Salvar", "Save")) || (enter && trackName[0])) { command("renameTrack", {{"projectID",modalProject},{"trackID", editTrack}, {"name", trackName.data()}}); ImGui::CloseCurrentPopup(); }
            ImGui::EndDisabled(); ImGui::SameLine(); if (ImGui::Button(tr("Cancelar", "Cancel"))) ImGui::CloseCurrentPopup();
            ImGui::EndPopup();
        }
        if (removeRequested) {captureDocument();modalTracks=tracks;ImGui::OpenPopup("##removeTracks"); removeRequested = false; }
        if (ImGui::BeginPopupModal("##removeTracks", nullptr, ImGuiWindowFlags_AlwaysAutoResize)) {
            if(staleDocument()){ImGui::CloseCurrentPopup();ImGui::EndPopup();return;}
            ImGui::TextWrapped("%s (%zu)", tr("Excluir as pistas selecionadas?", "Delete the selected tracks?"), modalTracks.size());
            if (ImGui::Button(tr("Cancelar", "Cancel"))) ImGui::CloseCurrentPopup();
            ImGui::SameLine();
            if (coloredButton(tr("Excluir", "Delete"), ImVec4(.85f, .23f, .25f, 1))) { command("removeTracks", {{"projectID",modalProject},{"trackIDs", modalTracks}}); ImGui::CloseCurrentPopup(); }
            ImGui::EndPopup();
        }
        if (!dialogs.empty() && !dialogOpen) { ImGui::OpenPopup("##message"); dialogOpen = true; }
        ImGui::SetNextWindowSize(ImVec2(460 * s, 0), ImGuiCond_Appearing);
        if (ImGui::BeginPopupModal("##message", nullptr, ImGuiWindowFlags_AlwaysAutoResize)) {
            if (!dialogs.empty()) {
                const auto dialog = dialogs.front();
                ImGui::TextWrapped("%s", string(dialog.message, "title", "CatLive").c_str()); ImGui::Separator();
                ImGui::PushTextWrapPos(ImGui::GetCursorPosX() + 425 * s);
                ImGui::TextUnformatted(string(dialog.message, "message").c_str()); ImGui::PopTextWrapPos();
                auto choices = field(dialog.message, "buttons");
                if (!choices.is_array() || choices.empty()) choices = JSON::array({JSON{{"id", "ok"}, {"label", "OK"}}});
                for (const auto& choice : choices) if (ImGui::Button((string(choice, "label", "OK") + "##" + string(choice, "id")).c_str(), ImVec2(-1, 30 * s))) {
                    dialogs.pop_front(); dialogOpen = false; ImGui::CloseCurrentPopup();
                    if (dialog.confirm) command("confirm", {{"token", string(dialog.message, "token")}, {"choice", string(choice, "id", "cancel")}});
                    break;
                }
            }
            ImGui::EndPopup();
        }
        if (flag(snapshot, "busy") && dialogs.empty() && !showAccount) ImGui::OpenPopup("##progress");
        ImGui::SetNextWindowSize(ImVec2(430 * s, 0), ImGuiCond_Appearing);
        if (ImGui::BeginPopupModal("##progress", nullptr, ImGuiWindowFlags_AlwaysAutoResize)) {
            if (!flag(snapshot, "busy") || !dialogs.empty()) ImGui::CloseCurrentPopup();
            ImGui::TextUnformatted(tr("Preparando projeto", "Preparing project"));
            ImGui::TextWrapped("%s", string(snapshot, "status").c_str());
            const auto progress = float(number(snapshot, "progress", -1));
            if (progress >= 0) {
                ImGui::PushStyleColor(ImGuiCol_PlotHistogram,ImVec4(.3f,.9f,.43f,1));
                ImGui::ProgressBar(std::clamp(progress, 0.f, 1.f), ImVec2(-1, 3 * s),"");ImGui::PopStyleColor();
            }
            else ImGui::TextDisabled("%s", tr("Aguarde...", "Please wait..."));
            ImGui::EndPopup();
        }
    }
    void effectsPanel();
    void render() {
        if (firstFrame) { firstFrame = false; command("snapshot"); }
        const auto now = Clock::now();
        for (auto it = pending.begin(); it != pending.end();) {
            if (now - it->second.began > std::chrono::seconds(60) && dialogs.empty() && !flag(snapshot, "busy")) {
                const auto call = std::move(it->second); const auto action = call.action; it = pending.erase(it);
                if (call.payload.contains("requestId"))
                    timeline.receive({{"type", "reply"}, {"requestId", call.payload["requestId"]}, {"ok", false}, {"error", "Waveform request timed out."}});
                if (action.rfind("effects", 0) == 0 && string(call.payload, "projectID") == string(project(), "id") && string(call.payload, "trackID") == fxTrack) {
                    fxLoading = false; fxCommitting = false;
                    if (action == "effectsCommit") { fxChain = fxVerified; fxDirty = false; }
                }
                if (action != "waveform") error(tr("O CatLive não respondeu ao comando.", "CatLive did not respond to the command."));
            } else ++it;
        }
        auto* viewport = ImGui::GetMainViewport();
        ImGui::SetNextWindowPos(viewport->WorkPos); ImGui::SetNextWindowSize(viewport->WorkSize);
        ImGui::PushStyleVar(ImGuiStyleVar_WindowRounding, 0);
        ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(6 * scale(), 6 * scale()));
        ImGui::PushStyleVar(ImGuiStyleVar_ItemSpacing, ImVec2(4 * scale(), 4 * scale()));
        ImGui::PushStyleColor(ImGuiCol_WindowBg, ImVec4(.075f, .08f, .09f, 1));
        ImGui::PushStyleColor(ImGuiCol_ChildBg, ImVec4(.10f, .11f, .12f, 1));
        ImGui::PushStyleColor(ImGuiCol_SliderGrab, ImVec4(.72f, .76f, .79f, 1));
        ImGui::PushStyleColor(ImGuiCol_SliderGrabActive, ImVec4(.36f, .72f, .98f, 1));
        ImGui::Begin("##CatLive", nullptr, ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoSavedSettings | ImGuiWindowFlags_NoBringToFrontOnFocus);
        toolbar();
        ImGui::TextDisabled("%s%s", string(field(snapshot, "document"), "name", string(project(), "name", "CatLive")).c_str(), flag(snapshot, "readOnly") ? tr("  / Somente leitura", "  / Read only") : "");
        ImGui::SameLine();
        const auto activeRegion = string(transport(), "regionID", string(transport(), "selectedRegionID"));
        for (const auto& part : array(field(song(), "parts"))) if (string(part, "id") == activeRegion) { ImGui::TextUnformatted(string(part, "name").c_str()); break; }
        ImGui::Separator();
        std::set<std::string> visible;
        const auto bodyHeight = std::max(40.f, ImGui::GetContentRegionAvail().y - 24 * scale() - (showFooter && !home ? 185 * scale() : 0));
        ImGui::BeginChild("##body", ImVec2(0, bodyHeight), ImGuiChildFlags_None, ImGuiWindowFlags_NoScrollbar);
        if (home) homePanel();
        else {
            if (showTracks) { trackPanel(bodyHeight, visible); ImGui::SameLine(); }
            const float rightWidth = showSetlist ? (setlistWidth + 4) * scale() : 0;
            ImGui::BeginChild("##timelinePanel", ImVec2(std::max(50.f, ImGui::GetContentRegionAvail().x - rightWidth), bodyHeight), ImGuiChildFlags_Borders, ImGuiWindowFlags_NoScrollbar);
            timeline.render(snapshot, telemetry, [this](const std::string& action, const JSON& payload) { command(action, payload); });
            ImGui::EndChild();
            if (showSetlist) { ImGui::SameLine(); setlistPanel(bodyHeight); }
        }
        ImGui::EndChild();
        if (showFooter && !home) footerMixer(visible);
        const auto nextViewport = JSON(visible).dump();
        if (nextViewport != viewportKey && !firstSnapshot) { viewportKey = nextViewport; command("viewport", {{"trackIDs", visible}}); }
        ImGui::Separator();
        ImGui::TextDisabled("%s", status.empty() ? tr("Pronto", "Ready") : status.c_str());
        if (!ImGui::GetIO().WantTextInput && !ImGui::IsPopupOpen("", ImGuiPopupFlags_AnyPopupId) && !fxOpen) {
            const auto& io = ImGui::GetIO();
            if (ImGui::IsKeyPressed(ImGuiKey_Space, false) && !io.KeyCtrl && !io.KeyAlt && !io.KeyShift && editable()) command("togglePlay");
            if (io.KeyCtrl && editable()) {
                if (ImGui::IsKeyPressed(ImGuiKey_O, false)) command("open");
                if (ImGui::IsKeyPressed(ImGuiKey_S, false)) command("save");
                if (ImGui::IsKeyPressed(ImGuiKey_Z, false)) command(io.KeyShift ? "redo" : "undo");
                if (ImGui::IsKeyPressed(ImGuiKey_Y, false)) command("redo");
            }
        }
        modalPanels();
        ImGui::End(); ImGui::PopStyleColor(4); ImGui::PopStyleVar(3);
        effectsPanel();
        acceptDrops=!fxOpen&&!showAccount&&dialogs.empty()&&!mediaRequested&&!mediaDrop.is_object()&&
            !ImGui::IsPopupOpen(nullptr,ImGuiPopupFlags_AnyPopupId|ImGuiPopupFlags_AnyPopupLevel);
    }
};

namespace {
const char* enabledKey(const std::string& kind) {
    if (kind == "EQ") return "eqEnabled";
    if (kind == "Compressor") return "compressorEnabled";
    if (kind == "Delay") return "delayEnabled";
    if (kind == "Reverb") return "reverbEnabled";
    if (kind == "Limiter") return "limiterEnabled";
    if (kind == "Pitch") return "pitchEnabled";
    if (kind == "Cat Gate") return "gateEnabled";
    if (kind == "CatLive Trigger") return "triggerEnabled";
    return nullptr;
}
struct EffectEntry { std::string kind, name; JSON* value = nullptr; };
EffectEntry effectEntry(JSON& chain, const std::string& key) {
    if (key.empty()) return {};
    if (chain.contains("instances") && chain["instances"].is_array())
        for (auto& entry : chain["instances"]) if (key == "Native:" + string(entry, "id") || key == "Instance:" + string(entry, "id"))
            return {string(entry, "kind"), string(entry, "kind"), &entry["settings"]};
    if (key.rfind("External:", 0) == 0) {
        if (chain.contains("externalPlugins") && chain["externalPlugins"].is_array())
            for (auto& entry : chain["externalPlugins"]) if (key == "External:" + string(entry, "id")) return {"External", string(entry, "name", key), &entry};
        return {"External", key, nullptr};
    }
    return {key, key, &chain};
}
std::string effectID(std::uint64_t serial) {
    const auto ticks = static_cast<std::uint64_t>(Clock::now().time_since_epoch().count());
    char value[48];
    std::snprintf(value, sizeof(value), "%08x-%04x-4%03x-8%03x-%012llx", unsigned(ticks >> 32), unsigned((ticks >> 16) & 0xffff), unsigned(ticks & 0xfff), unsigned(serial & 0xfff), static_cast<unsigned long long>((ticks ^ (serial << 24)) & 0xffffffffffffULL));
    return value;
}
JSON effectDefaults(const std::string& kind, std::uint64_t serial) {
    JSON result = {{"inserted", JSON::array()}, {"bands", JSON::array()}, {"eqEnabled", false}, {"compressorEnabled", false},
        {"delayEnabled", false}, {"reverbEnabled", false}, {"threshold", -20.}, {"ratio", 4.}, {"attack", .005}, {"release", .1}, {"makeup", 0.},
        {"delayTime", .25}, {"feedback", 25.}, {"delayMix", 20.}, {"reverbRoom", 1}, {"reverbMix", 20.}, {"reverbDecay", 2.},
        {"reverbLowCut", 80.}, {"reverbHighCut", 12000.}, {"pitchSemitones", 0.},
        {"limiter", {{"inputGain", 0.}, {"ceiling", -.1}, {"release", .1}}},
        {"gate", {{"threshold", -40.}, {"attack", .001}, {"decay", .02}, {"hold", .05}, {"release", .1}, {"highPass", 20.}, {"lowPass", 20000.}, {"filterOutput", false}}},
        {"trigger", {{"threshold", -30.}, {"retrigger", .08}, {"gain", 0.}, {"mix", 100.}, {"attack", 0.}, {"decay", .1}, {"sustain", 1.}, {"release", .02}}}};
    if (const auto* key = enabledKey(kind)) result[key] = true;
    if (kind == "EQ") {
        const double frequencies[]{30, 200, 1000, 5000, 18000};
        for (int n = 0; n < 5; ++n) result["bands"].push_back({{"id", effectID(serial + n + 1)}, {"frequency", frequencies[n]}, {"gain", 0.},
            {"q", .707}, {"type", n == 0 ? "lowCut" : n == 4 ? "highCut" : "bell"}, {"slope", 12}, {"enabled", true}});
    }
    return result;
}
}

void ImGuiFrontendView::Impl::effectsPanel() {
    if (!fxOpen) return;
    const auto s = scale();
    ImGui::SetNextWindowSize(ImVec2(740 * s, 490 * s), ImGuiCond_FirstUseEver);
    bool open = true;
    const bool visible = ImGui::Begin(("FX - " + fxName + "###nativeEffects").c_str(), &open, ImGuiWindowFlags_NoSavedSettings);
    auto commit = [&] {
        if (!fxDirty || fxCommitting || fxLoading) return;
        fxDirty = false; fxCommitting = true;
        command("effectsCommit", {{"trackID", fxTrack}, {"settings", fxChain}});
    };
    auto preview = [&](const std::string& key) {
        const auto entry = effectEntry(fxChain, key);
        if (entry.value && enabledKey(entry.kind))
            command("effectsPreview", {{"trackID", fxTrack}, {"key", key}, {"kind", entry.kind}, {"settings", *entry.value}, {"chainSettings", fxChain}});
    };
    if (visible) {
        if (fxLoading) ImGui::TextDisabled("%s", tr("Carregando efeitos...", "Loading effects..."));
        else {
            ImGui::BeginDisabled(!editable() || fxCommitting);
            ImGui::BeginChild("##chain", ImVec2(180 * s, -46 * s), ImGuiChildFlags_Borders);
            for (const auto& value : array(field(fxChain, "inserted"))) if (value.is_string()) {
                const auto key = value.get<std::string>(); const auto entry = effectEntry(fxChain, key);
                if (ImGui::Selectable((entry.name + "##" + key).c_str(), fxSelected == key)) { commit(); fxSelected = key; }
            }
            ImGui::Separator();
            if (ImGui::Button(tr("+ Adicionar efeito", "+ Add effect"), ImVec2(-1, 0))) ImGui::OpenPopup("##addEffect");
            if (ImGui::BeginPopup("##addEffect")) {
                const char* kinds[]{"EQ", "Compressor", "Delay", "Reverb", "Limiter", "Pitch", "Cat Gate", "CatLive Trigger"};
                for (const auto* kind : kinds) if (ImGui::MenuItem(kind)) {
                    if (!fxChain["instances"].is_array()) fxChain["instances"] = JSON::array();
                    if (!fxChain["inserted"].is_array()) fxChain["inserted"] = JSON::array();
                    const auto id = effectID(++serial); fxSelected = "Native:" + id;
                    fxChain["instances"].push_back({{"id", id}, {"kind", kind}, {"settings", effectDefaults(kind, serial)}});
                    fxChain["inserted"].push_back(fxSelected); fxDirty = true; commit();
                }
                ImGui::EndPopup();
            }
            ImGui::EndChild(); ImGui::SameLine();
            ImGui::BeginChild("##effectControls", ImVec2(0, -46 * s), ImGuiChildFlags_Borders);
            auto entry = effectEntry(fxChain, fxSelected);
            if (!entry.value) ImGui::TextWrapped("%s", tr("Selecione ou adicione um efeito.", "Select or add an effect."));
            else {
                ImGui::TextUnformatted(entry.name.c_str());
                const auto* enable = enabledKey(entry.kind);
                if (enable || entry.kind == "External") {
                    bool enabled = entry.kind == "External" ? !flag(*entry.value, "bypassed") : flag(*entry.value, enable);
                    if (ImGui::Checkbox(tr("Ativado", "Enabled"), &enabled)) { (*entry.value)[entry.kind == "External" ? "bypassed" : enable] = entry.kind == "External" ? !enabled : enabled; fxDirty = true; commit(); }
                }
                ImGui::SameLine();
                if (ImGui::SmallButton(tr("Remover", "Remove"))) ImGui::OpenPopup("##removeEffect");
                if (ImGui::BeginPopup("##removeEffect")) {
                    ImGui::TextWrapped("%s", tr("Remover este efeito?", "Remove this effect?"));
                    if (ImGui::Button(tr("Remover", "Remove"))) {
                        auto& inserted = fxChain["inserted"];
                        inserted.erase(std::remove(inserted.begin(), inserted.end(), JSON(fxSelected)), inserted.end());
                        // Keep unreferenced settings intact for round-trip compatibility.
                        fxSelected = inserted.empty() ? std::string() : inserted.front().get<std::string>();
                        fxDirty = true; commit(); ImGui::CloseCurrentPopup(); entry = {};
                    }
                    ImGui::EndPopup();
                }
                if (entry.value) {
                    ImGui::Separator();
                    const auto defaults = effectDefaults(entry.kind, serial);
                    auto control = [&](const char* label, const char* path, float minimum, float maximum, float factor = 1.f, const char* format = "%.2f") {
                        JSON* target = entry.value; const JSON* fallback = &defaults;
                        std::string key = path; const auto dot = key.find('.');
                        if (dot != std::string::npos) {
                            const auto objectKey = key.substr(0, dot); key = key.substr(dot + 1);
                            fallback = &field(*fallback, objectKey.c_str());
                            if (!(*target)[objectKey].is_object()) (*target)[objectKey] = JSON::object();
                            target = &(*target)[objectKey];
                        }
                        float value = float(number(*target, key.c_str(), number(*fallback, key.c_str()))) * factor;
                        ImGui::SetNextItemWidth(std::max(80.f, ImGui::GetContentRegionAvail().x * .62f));
                        const bool changed = ImGui::SliderFloat(label, &value, minimum, maximum, format);
                        if (changed) {
                            (*target)[key] = value / factor; fxDirty = true;
                            if (ImGui::GetTime() - lastFXPreview >= .05) { lastFXPreview = ImGui::GetTime(); preview(fxSelected); }
                        }
                        if (ImGui::IsItemDeactivatedAfterEdit()) { preview(fxSelected); commit(); }
                    };
                    if (entry.kind == "Compressor") {
                        control("Threshold", "threshold", -60, 0, 1, "%.1f dB"); control("Ratio", "ratio", 1, 20, 1, "%.1f:1");
                        control("Gain", "makeup", -12, 24, 1, "%.1f dB"); control("Attack", "attack", .1f, 200, 1000, "%.1f ms"); control("Release", "release", 10, 3000, 1000, "%.0f ms");
                    } else if (entry.kind == "Delay") {
                        control("Time", "delayTime", 10, 2000, 1000, "%.0f ms"); control("Feedback", "feedback", 0, 90, 1, "%.1f %%"); control("Mix", "delayMix", 0, 100, 1, "%.1f %%");
                    } else if (entry.kind == "Reverb") {
                        control("Mix", "reverbMix", 0, 100, 1, "%.1f %%"); control("Decay", "reverbDecay", .1f, 20, 1, "%.1f s");
                        control("Low Cut", "reverbLowCut", 20, 2000, 1, "%.0f Hz"); control("High Cut", "reverbHighCut", 2000, 20000, 1, "%.0f Hz");
                    } else if (entry.kind == "Limiter") {
                        control("Input", "limiter.inputGain", -24, 24, 1, "%.1f dB"); control("Ceiling", "limiter.ceiling", -24, 0, 1, "%.1f dB"); control("Release", "limiter.release", 10, 3000, 1000, "%.0f ms");
                    } else if (entry.kind == "Pitch") control("Semitones", "pitchSemitones", -12, 12, 1, "%.1f st");
                    else if (entry.kind == "Cat Gate") {
                        control("Threshold", "gate.threshold", -80, 0, 1, "%.1f dB"); control("Attack", "gate.attack", 0, 2000, 1000, "%.0f ms");
                        control("Decay", "gate.decay", 0, 2000, 1000, "%.0f ms"); control("Hold", "gate.hold", 0, 2000, 1000, "%.0f ms"); control("Release", "gate.release", 0, 5000, 1000, "%.0f ms");
                        control("High Pass", "gate.highPass", 20, 20000, 1, "%.0f Hz"); control("Low Pass", "gate.lowPass", 20, 20000, 1, "%.0f Hz");
                        bool filter = flag(field(*entry.value, "gate"), "filterOutput");
                        if (ImGui::Checkbox("Filter output", &filter)) { (*entry.value)["gate"]["filterOutput"] = filter; fxDirty = true; preview(fxSelected); commit(); }
                    } else if (entry.kind == "CatLive Trigger") {
                        ImGui::TextWrapped("%s", string(field(*entry.value, "trigger"), "samplePath", tr("Sem sample", "No sample")).c_str());
                        if (ImGui::Button(tr("Escolher sample...", "Choose sample..."))) command("effectsChooseSample", {{"trackID", fxTrack}, {"key", fxSelected}});
                        control("Threshold", "trigger.threshold", -80, 0, 1, "%.1f dB"); control("Retrigger", "trigger.retrigger", 5, 2000, 1000, "%.0f ms");
                        control("Gain", "trigger.gain", -24, 24, 1, "%.1f dB"); control("Mix", "trigger.mix", 0, 100, 1, "%.1f %%");
                        control("Attack", "trigger.attack", 0, 10000, 1000, "%.0f ms"); control("Decay", "trigger.decay", 0, 10000, 1000, "%.0f ms");
                        control("Sustain", "trigger.sustain", 0, 100, 100, "%.1f %%"); control("Release", "trigger.release", 0, 20000, 1000, "%.0f ms");
                    } else if (entry.kind == "EQ") {
                        if (!(*entry.value)["bands"].is_array()) (*entry.value)["bands"] = JSON::array();
                        int index = 0;
                        for (auto& band : (*entry.value)["bands"]) {
                            ImGui::PushID(index++); bool enabled = flag(band, "enabled", true);
                            bool changed = ImGui::Checkbox("##bandEnabled", &enabled);
                            if (changed) band["enabled"] = enabled;
                            ImGui::SameLine(); ImGui::Text("Band %d", index);
                            const auto currentType = string(band, "type", "bell");
                            if (ImGui::BeginCombo("Type", currentType.c_str())) {
                                for (const auto* type : {"bell", "lowCut", "highCut", "lowShelf", "highShelf"})
                                    if (ImGui::Selectable(type, currentType == type)) { band["type"] = type; changed = true; }
                                ImGui::EndCombo();
                            }
                            bool finish = false;
                            for (const auto* key : {"frequency", "gain", "q"}) {
                                float value = float(number(band, key, std::string(key) == "frequency" ? 1000 : std::string(key) == "q" ? .707 : 0));
                                const auto frequency = std::string(key) == "frequency", q = std::string(key) == "q";
                                if (ImGui::SliderFloat(key, &value, frequency ? 20.f : q ? .1f : -24.f, frequency ? 20000.f : q ? 18.f : 24.f,
                                                      frequency ? "%.0f Hz" : q ? "%.2f" : "%.1f dB", frequency ? ImGuiSliderFlags_Logarithmic : ImGuiSliderFlags_None)) { band[key] = value; changed = true; }
                                finish |= ImGui::IsItemDeactivatedAfterEdit();
                            }
                            if (changed) { fxDirty = true; if (ImGui::GetTime() - lastFXPreview >= .05) { lastFXPreview = ImGui::GetTime(); preview(fxSelected); } }
                            if (finish) { preview(fxSelected); commit(); }
                            ImGui::Separator(); ImGui::PopID();
                        }
                    } else ImGui::TextWrapped("%s", tr("Este efeito mantém os ajustes salvos no projeto. Seu editor dedicado ainda não está disponível nesta interface.", "This effect retains its saved project settings. Its dedicated editor is not yet available in this interface."));
                }
            }
            ImGui::EndChild(); ImGui::EndDisabled();
        }
        if (!fxError.empty()) ImGui::TextColored(ImVec4(1, .42f, .42f, 1), "%s", fxError.c_str());
        ImGui::BeginDisabled(fxLoading || fxCommitting || !editable());
        if (ImGui::Button(tr("Aplicar", "Apply"))) commit();
        ImGui::SameLine();
        if (ImGui::Button(tr("Descartar ajustes", "Discard changes"))) {
            fxChain = fxVerified; fxDirty = false;
            for (const auto& key : array(field(fxChain, "inserted"))) if (key.is_string()) preview(key.get<std::string>());
        }
        ImGui::EndDisabled(); ImGui::SameLine();
        if (ImGui::Button(tr("Fechar", "Close"))) open = false;
        if (fxCommitting) { ImGui::SameLine(); ImGui::TextDisabled("%s", tr("Salvando...", "Saving...")); }
    }
    ImGui::End();
    if (!open) { commit(); fxOpen = false; }
}

ImGuiFrontendView::ImGuiFrontendView(std::function<void(std::string)> emit) : impl(std::make_unique<Impl>(std::move(emit))) {}
ImGuiFrontendView::~ImGuiFrontendView() = default;
void ImGuiFrontendView::receive(const std::string& json) { impl->receive(json); }
void ImGuiFrontendView::render() { impl->render(); }
}
