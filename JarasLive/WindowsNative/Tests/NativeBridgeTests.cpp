#include "NativeBridge.h"
#include "ProjectCodec.h"
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>

using namespace catlive::native;
static void require(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
static nlohmann::json request(CatLiveDocument* document, const nlohmann::json& value) {
    const auto bytes = value.dump();
    std::unique_ptr<char, decltype(&catlive_document_free_response)> response(
        catlive_document_request(document, bytes.data(), bytes.size()), catlive_document_free_response);
    require(response != nullptr, "FFI returns a response");
    return nlohmann::json::parse(response.get());
}
int main() {
    std::unique_ptr<CatLiveDocument, decltype(&catlive_document_destroy)> handle(
        catlive_document_create(), catlive_document_destroy);
    require(handle != nullptr, "FFI creates handle");
    jaras::Project project; project.id = "project"; project.name = u8"Sessão – violão 🎹";
    jaras::Song song; song.id = "song"; song.name = "Song"; song.duration = 123.45678901234567;
    project.songs.push_back(song); project.setlists.push_back({"setlist", "Show", {"song"}});
    jaras::synchronizeRegionOwnership(project);
    auto document = ProjectCodec::encode(project);
    document["futureExtension"] = {{"unknown", {1, false, nullptr, u8"音楽"}}};
    auto loaded = request(handle.get(), {{"operation", "load"}, {"document", document}});
    require(loaded["ok"] == true, "valid document loads across C boundary");
    auto original = request(handle.get(), {{"operation", "document"}});
    require(original["data"] == document, "UTF-8, double precision and future fields roundtrip");
    require(request(handle.get(), {{"operation", "load"}, {"document", nullptr}})["ok"] == false,
            "invalid document returns a structured error");
    require(request(handle.get(), {{"operation", "invalid"}})["ok"] == false, "unknown operations rejected");
    require(request(nullptr, {{"operation", "state"}})["ok"] == false, "null handle rejected");
    require(request(handle.get(), {{"operation", "document"}}) == original, "failure preserves document");
    auto prepared = request(handle.get(), {{"operation", "prepareRecordingProject"}, {"name", "REC Guilherme"}, {"channels", 32}});
    require(prepared["ok"] == true && prepared["data"]["armedTrackIds"].size() == 32, "REC Multitrack did not prepare 32 armed tracks");
    const auto tracks = ProjectCodec::decode(prepared["data"]["document"]).songs[0].tracks;
    require(tracks.size() == 32 && tracks[31].inputPatch->firstChannel == 32
        && tracks[31].recordingChannels == 1 && tracks[31].inputMonitoring == false, "REC preparation lost input/mono/monitor settings");
    require(request(handle.get(), {{"operation", "document"}}) == original, "preparing a new project replaced current unsaved work");
    require(request(handle.get(), {{"operation", "prepareRecordingProject"}, {"name", "REC"}, {"channels", 32.5}})["ok"] == false,
            "fractional channel count accepted");
    auto* invalid = catlive_document_request(handle.get(), "{", 1);
    require(invalid != nullptr && nlohmann::json::parse(invalid)["ok"] == false, "invalid JSON caught across ABI");
    catlive_document_free_response(invalid);
    catlive_document_free_response(nullptr);
    catlive_document_destroy(nullptr);
    std::cout << "NATIVE_BRIDGE_UTF8_PRECISION_ERRORS_OWNERSHIP_OK\n";
}
