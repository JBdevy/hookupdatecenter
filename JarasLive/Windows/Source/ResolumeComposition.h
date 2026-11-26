#pragma once
#include "Lighting.h"
namespace catlive {
// Mirrors Application/Resolume/ResolumeComposition.swift. Every mutation is
// confirmed by a fresh composition read; an ambiguous POST is never repeated.
class ResolumeComposition {
  public:
    struct Deck {
        int number = 1;
        String name;
        std::map<int, String> columns;
    };
    struct Plan {
        String name;
        std::map<int, Deck> decks;
    };
    struct HTTPError : std::runtime_error {
        int status;
        explicit HTTPError(int code)
            : std::runtime_error("Resolume HTTP " + std::to_string(code)), status(code) {}
    };
    struct Unconfirmed : std::runtime_error {
        Unconfirmed() : std::runtime_error("Resolume did not confirm the request.") {}
    };
    using Request =
        std::function<var(const String &, const String &, const String &, const String &)>;
    static Plan plan(const Lighting &lighting, const String &name) {
        Plan result;
        result.name = Lighting::cleanName(name, "Projeto CatLive");
        for (const auto &region : lighting.resolumeRegions)
            for (size_t i = 0; i < region.cues.size(); ++i)
                if (i == 0 || lighting.includeMarkers) {
                    auto key = Identifier((i == 0 ? "region:" : "marker:") +
                                          text(i == 0 ? region.id : region.cues[i].id));
                    auto pair = StringArray::fromTokens(get(lighting.includeMarkers
                                                                ? lighting.resolumeAssignments
                                                                : lighting.resolumeRegionsOnly,
                                                            key)
                                                            .toString(),
                                                        ":", {});
                    if (pair.size() != 2)
                        continue;
                    const int deck = pair[0].getIntValue() + 1, column = pair[1].getIntValue() + 1;
                    if (deck < 1 || deck > 1000 || column < 1 || column > 10000)
                        throw std::runtime_error("O mapa excede 1.000 decks ou 10.000 colunas.");
                    auto &entry = result.decks[deck];
                    entry.number = deck;
                    entry.name = Lighting::cleanName(region.name, "Musica");
                    entry.columns[column] = Lighting::cleanName(region.cues[i].name);
                }
        if (result.decks.empty())
            throw std::runtime_error("Crie um mapa Resolume com músicas primeiro.");
        return result;
    }
    static Request network(String host, int port) {
        host = host.trim();
        if (host.isEmpty() || host.containsAnyOf("/\\?#@ \r\n\t") || port < 1 || port > 65535)
            throw std::runtime_error("Endereço ou porta Webserver inválidos.");
        if (host.containsChar(':') && !host.startsWithChar('['))
            host = "[" + host + "]";
        const auto base = "http://" + host + ":" + String(port) + "/api/v1";
        return [base](const String &path, const String &method, const String &body,
                      const String &type) {
            URL url(base + path);
            if (body.isNotEmpty())
                url = url.withPOSTData(body);
            int status = 0;
            auto stream = url.createInputStream(
                URL::InputStreamOptions(URL::ParameterHandling::inAddress)
                    .withHttpRequestCmd(method)
                    .withExtraHeaders("Content-Type: " + type + "\r\nCache-Control: no-cache\r\n")
                    .withConnectionTimeoutMs(8000)
                    .withNumRedirectsToFollow(0)
                    .withStatusCode(&status));
            if (!stream || status == 0)
                throw Unconfirmed();
            if (status < 200 || status >= 300)
                throw HTTPError(status);
            MemoryOutputStream bytes;
            std::array<char, 8192> buffer{};
            while (!stream->isExhausted()) {
                const int count = stream->read(buffer.data(), (int)buffer.size());
                if (count <= 0)
                    break;
                if (bytes.getDataSize() + count > 32 * 1024 * 1024)
                    throw std::runtime_error("Resposta Resolume grande demais.");
                bytes.write(buffer.data(), count);
            }
            auto value = JSON::parse(bytes.toUTF8());
            return value.isObject() ? value : object();
        };
    }
    ResolumeComposition(Request request, std::function<bool()> stopped = {},
                        std::function<void(String)> progress = {})
        : request(std::move(request)), cancelled(std::move(stopped)),
          progress(std::move(progress)) {}
    void create(const Plan &plan, const File &destination) {
        if (plan.decks.empty() || plan.decks.rbegin()->first > 1000)
            throw std::runtime_error("Crie o mapa Resolume primeiro.");
        if (destination.exists())
            throw std::runtime_error("Escolha um novo arquivo .avc para preservar o existente.");
        const auto product = call("/product");
        const int major = (int)num(product, "major"), minor = (int)num(product, "minor");
        if (!str(product, "name").containsIgnoreCase("arena") || major < 7 ||
            (major == 7 && minor < 22))
            throw std::runtime_error(
                "A criação automática exige Resolume Arena 7.22 ou mais recente.");
        auto composition = call("/composition");
        auto decks = list(get(composition, "decks"));
        if (decks.isEmpty())
            throw std::runtime_error("Abra uma composição nova e vazia no Resolume.");
        for (const auto &deck : decks)
            if (!blank(deck))
                throw std::runtime_error("Abra uma composição nova e vazia no Resolume.");
        for (int index = 1; index <= decks.size(); ++index) {
            composition = select(index);
            for (const auto &layer : list(get(composition, "layers")))
                for (const auto &clip : list(get(layer, "clips"))) {
                    const auto audio = get(clip, "audio"), video = get(clip, "video");
                    const auto connected = str(get(clip, "connected"), "value");
                    if ((!audio.isVoid() && !audio.isUndefined()) ||
                        (!video.isVoid() && !video.isUndefined()) ||
                        (connected.isNotEmpty() && connected != "Empty"))
                        throw std::runtime_error("A composição do Resolume contém mídia. Abra uma "
                                                 "composição nova e vazia.");
                }
        }
        while (list(get(composition, "decks")).size() > 1) {
            const int before = list(get(composition, "decks")).size();
            composition = mutate("/composition/decks/" + String(before), "DELETE", {},
                                 [before](const var &value) {
                                     return list(get(value, "decks")).size() == before - 1;
                                 });
        }
        const int total = plan.decks.rbegin()->first;
        while (list(get(composition, "decks")).size() < total) {
            const int before = list(get(composition, "decks")).size();
            composition = mutate("/composition/decks/add", "POST", {}, [before](const var &value) {
                return list(get(value, "decks")).size() == before + 1;
            });
        }
        auto body = object();
        put(body, "name", parameter(plan.name));
        Array<var> renamed;
        StringArray names;
        decks = list(get(composition, "decks"));
        for (int i = 0; i < total; ++i) {
            const auto found = plan.decks.find(i + 1);
            const auto name =
                found == plan.decks.end() ? "Reserved " + String(i + 1) : found->second.name;
            names.add(name);
            auto deck = object();
            put(deck, "id", get(decks[i], "id"));
            put(deck, "name", parameter(name));
            renamed.add(deck);
        }
        put(body, "decks", renamed);
        composition = mutate("/composition", "PUT", body, [&](const var &value) {
            auto result = list(get(value, "decks"));
            if (name(value) != plan.name || result.size() != names.size())
                return false;
            for (int i = 0; i < result.size(); ++i)
                if (name(result[i]) != names[i])
                    return false;
            return true;
        });
        for (int index = 1; index <= total; ++index) {
            if (progress)
                progress("Criando deck " + String(index) + " / " + String(total));
            composition = select(index);
            const auto found = plan.decks.find(index);
            const std::map<int, String> empty;
            const auto &columns = found == plan.decks.end() ? empty : found->second.columns;
            const int count = columns.empty() ? 1 : columns.rbegin()->first;
            if (list(get(composition, "columns")).size() < count) {
                auto grow = object();
                put(grow, "column_count", count);
                composition =
                    mutate("/composition/grow-to", "POST", grow, [count](const var &value) {
                        return list(get(value, "columns")).size() >= count;
                    });
            }
            while (list(get(composition, "columns")).size() > count) {
                const int before = list(get(composition, "columns")).size();
                composition = mutate("/composition/columns/" + String(before), "DELETE", {},
                                     [before](const var &value) {
                                         return list(get(value, "columns")).size() == before - 1;
                                     });
            }
            for (const auto &[column, title] : columns)
                if (title.isNotEmpty()) {
                    auto update = object();
                    put(update, "name", parameter(title));
                    composition = mutate("/composition/columns/" + String(column), "PUT", update,
                                         [&](const var &value) {
                                             auto result = list(get(value, "columns"));
                                             return column <= result.size() &&
                                                    name(result[column - 1]) == title;
                                         });
                }
        }
        select(1);
        destination.getParentDirectory().createDirectory();
        try {
            check();
            request("/composition/save", "POST", URL(destination).toString(false), "text/plain");
        } catch (const Unconfirmed &) {
        }
        const auto deadline = Time::getMillisecondCounterHiRes() + 30000;
        while (Time::getMillisecondCounterHiRes() < deadline) {
            check();
            if (destination.existsAsFile() && destination.getSize() > 0)
                return;
            Thread::sleep(180);
        }
        throw std::runtime_error("O Resolume não confirmou o arquivo .avc. Verifique o Webserver e "
                                 "salve a composição no Resolume.");
    }
    static var parameter(const String &value) {
        auto result = object();
        put(result, "value", value);
        return result;
    }

  private:
    Request request;
    std::function<bool()> cancelled;
    std::function<void(String)> progress;
    void check() const {
        if (cancelled && cancelled())
            throw std::runtime_error(
                "Criação cancelada. Confira a composição no Resolume antes de tentar novamente.");
    }
    var call(const String &path) {
        check();
        return request(path, "GET", {}, "application/json");
    }
    static String name(const var &value) { return str(get(value, "name"), "value"); }
    static bool blank(const var &value) {
        auto label = name(value).trim().toLowerCase();
        return label.isEmpty() || label == "empty" ||
               (label.startsWith("empty ") && label.substring(6).isNotEmpty() &&
                label.substring(6).containsOnly("0123456789"));
    }
    var wait(const std::function<bool(const var &)> &predicate, int seconds = 15) {
        const auto deadline = Time::getMillisecondCounterHiRes() + seconds * 1000.;
        while (Time::getMillisecondCounterHiRes() < deadline) {
            check();
            try {
                auto value = call("/composition");
                if (predicate(value))
                    return value;
            } catch (const HTTPError &error) {
                if (error.status != 404 && error.status != 412)
                    throw;
            }
            Thread::sleep(180);
        }
        throw std::runtime_error(
            "O Resolume não confirmou a operação. Confira a composição antes de tentar novamente.");
    }
    var mutate(const String &path, const String &method, const var &body,
               const std::function<bool(const var &)> &predicate) {
        for (int attempt = 0; attempt < 4; ++attempt) {
            check();
            try {
                request(path, method, body.isObject() ? JSON::toString(body, true) : String(),
                        "application/json");
            } catch (const HTTPError &error) {
                if (error.status != 412)
                    throw;
                try {
                    return wait(predicate, 2);
                } catch (const std::exception &) {
                }
                if (attempt == 3)
                    throw;
                Thread::sleep(400);
                continue;
            } catch (const Unconfirmed &) {
                return wait(predicate, 30);
            }
            return wait(predicate);
        }
        throw std::runtime_error("O Resolume está ocupado.");
    }
    var select(int index) {
        return mutate("/composition/decks/" + String(index) + "/select", "POST", {},
                      [index](const var &value) {
                          auto decks = list(get(value, "decks"));
                          return index <= decks.size() &&
                                 flag(get(decks[index - 1], "selected"), "value");
                      });
    }
};
} // namespace catlive
