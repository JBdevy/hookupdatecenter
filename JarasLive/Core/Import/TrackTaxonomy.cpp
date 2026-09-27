#include "TrackTaxonomy.hpp"
#include <algorithm>
#include <cctype>
namespace jaras {
static std::string normalize(std::string s) {
    const std::vector<std::pair<std::string,std::string>> accents = {{"á","a"},{"à","a"},{"ã","a"},{"â","a"},{"Á","a"},{"À","a"},{"Ã","a"},{"Â","a"},{"é","e"},{"ê","e"},{"É","e"},{"Ê","e"},{"í","i"},{"Í","i"},{"ó","o"},{"ô","o"},{"õ","o"},{"Ó","o"},{"Ô","o"},{"Õ","o"},{"ú","u"},{"Ú","u"},{"ç","c"},{"Ç","c"}};
    for (const auto& pair : accents) { size_t at = 0; while ((at = s.find(pair.first, at)) != std::string::npos) { s.replace(at, pair.first.size(), pair.second); at += pair.second.size(); } }
    std::transform(s.begin(), s.end(), s.begin(), [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return s;
}
TrackTaxonomy::TrackTaxonomy() {
    const std::vector<std::pair<std::string,std::vector<std::string>>> roles = {
        {"click",{"click","clk","metronome","metronomo"}}, {"guide",{"guide","guia"}},
        {"drums",{"drums","bateria"}}, {"bass",{"bass","baixo"}}, {"guitar",{"guitar","guitarra"}},
        {"keys",{"keys","piano","teclado"}}, {"accordion",{"sanfona","accordion","acordeon","acc"}},
        {"backingVocal",{"backing vocal","backing","bgv"}}, {"fx",{"fx","effects","efeitos"}}
    };
    for (const auto& pair : roles) for (const auto& alias : pair.second) addAlias(alias, {pair.first});
}
void TrackTaxonomy::addAlias(std::string alias, TrackRole role) {
    aliases_.push_back({normalize(std::move(alias)), std::move(role)});
    std::stable_sort(aliases_.begin(), aliases_.end(), [](const auto& a, const auto& b) { return a.alias.size() > b.alias.size(); });
}
TrackRole TrackTaxonomy::classify(std::string filename) const {
    auto separator = filename.find_last_of("/\\"); if (separator != std::string::npos) filename = filename.substr(separator + 1);
    auto dot = filename.find_last_of('.'); if (dot != std::string::npos) filename.resize(dot);
    filename = normalize(filename);
    for (const auto& item : aliases_) {
        if (filename == item.alias || (filename.rfind(item.alias, 0) == 0 && filename.size() > item.alias.size() && !std::isalnum(static_cast<unsigned char>(filename[item.alias.size()])))) return item.role;
    }
    return {"other"};
}
}
