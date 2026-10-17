#include "NativeBridge.h"
#include "NativeSession.h"
#include "SessionActions.h"
#include "ProjectCreation.h"
#include "Identifier.h"
#include <cstdlib>
#include <cstring>
#include <new>
#include <stdexcept>

using namespace catlive::native;
struct CatLiveDocument { NativeSession session; };
namespace {
char* response(const nlohmann::json& value) {
    const auto utf8 = value.dump(-1, ' ', false, nlohmann::json::error_handler_t::replace);
    auto* result = static_cast<char*>(std::malloc(utf8.size() + 1));
    if (result) std::memcpy(result, utf8.c_str(), utf8.size() + 1);
    return result;
}
std::filesystem::path pathArgument(const nlohmann::json& request) {
    const auto value = request.at("path").get<std::string>();
    if (value.empty() || value.find('\0') != std::string::npos)
        throw std::invalid_argument("Caminho de projeto inválido.");
    return std::filesystem::u8path(value);
}
}
extern "C" CatLiveDocument* catlive_document_create(void) {
    try { return new CatLiveDocument; } catch (...) { return nullptr; }
}
extern "C" void catlive_document_destroy(CatLiveDocument* document) { delete document; }
extern "C" void catlive_document_free_response(char* value) { std::free(value); }
extern "C" char* catlive_document_request(CatLiveDocument* document, const char* bytes, size_t length) {
    try {
        if (!document || !bytes || length == 0 || length > 128 * 1024 * 1024)
            throw std::invalid_argument("Requisição de projeto inválida.");
        const auto request = nlohmann::json::parse(bytes, bytes + length);
        const auto operation = request.at("operation").get<std::string>();
        auto& session = document->session;
        nlohmann::json result;
        if (operation == "state") result = session.state();
        else if (operation == "document") result = session.document();
        else if (operation == "prepareRecordingProject") {
            const auto& count = request.at("channels");
            if (!count.is_number_integer() || count.get<std::int64_t>() < 1
                || count.get<std::int64_t>() > static_cast<std::int64_t>(maximumRecordingChannels))
                throw std::invalid_argument("Escolha de 1 a 128 canais para gravar.");
            auto prepared = createRecordingProject(request.at("name").get<std::string>(),
                count.get<std::size_t>(), freshIdentifier, request.value("trackNamePrefix", "Pista"));
            result = {{"document", std::move(prepared.document)}, {"armedTrackIds", prepared.armedTrackIDs}};
        }
        else if (operation == "load") {
            session.loadDocument(request.at("document")); result = session.state();
        } else if (operation == "open") {
            session.open(pathArgument(request)); result = session.state();
        } else if (operation == "save") {
            session.save(pathArgument(request)); result = session.state();
        } else if (operation == "action") result = applySessionAction(session, request.at("request"));
        else throw std::invalid_argument("Operação de projeto desconhecida.");
        return response({{"ok", true}, {"data", std::move(result)}});
    } catch (const std::exception& error) {
        try { return response({{"ok", false}, {"error", error.what()}}); } catch (...) { return nullptr; }
    } catch (...) { return nullptr; }
}
