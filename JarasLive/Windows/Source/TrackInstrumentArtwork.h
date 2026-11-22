#pragma once
#include "TrackInstrumentIcons.h"

namespace catlive::trackIcons {
struct Artwork {
    String id, title;
    File file;
};

struct Category {
    String name;
    StringArray legacy;
    std::vector<Artwork> artwork;
};

inline const std::vector<Category> &categories() {
    static const auto value = [] {
        const auto root = File::getSpecialLocation(File::currentExecutableFile).getSiblingFile("TrackIcons");
        std::vector<Category> result;
        for (const auto &entry : list(JSON::parse(root.getChildFile("categories.json")))) {
            Category category;
            category.name = str(entry, "name");
            if (category.name.isEmpty()) continue;
            for (const auto &id : list(get(entry, "legacy"))) category.legacy.add(id.toString());
            for (const auto &file : root.getChildFile(category.name).findChildFiles(File::findFiles | File::ignoreHiddenFiles, false, "*.png")) {
                const auto name = file.getFileNameWithoutExtension();
                auto title = StringArray::fromTokens(name, "-", {});
                for (int i = 0; i < title.size(); ++i) {
                    const auto word = title[i];
                    title.set(i, word.substring(0, 1).toUpperCase() + word.substring(1));
                }
                category.artwork.push_back({"png:" + category.name + "/" + name, title.joinIntoString(" "), file});
            }
            std::sort(category.artwork.begin(), category.artwork.end(), [](const auto &a, const auto &b) {
                return a.title.compareNatural(b.title) < 0;
            });
            result.push_back(std::move(category));
        }
        if (result.empty()) {
            Category fallback;
            fallback.name = "Other";
            for (const auto &icon : catalog()) fallback.legacy.add(icon.id);
            result.push_back(std::move(fallback));
        }
        return result;
    }();
    return value;
}

inline const Artwork *findArtwork(const std::optional<std::string> &id) {
    if (id && id->compare(0, 4, "png:") == 0)
        for (const auto &category : categories())
            for (const auto &artwork : category.artwork)
                if (*id == utf8(artwork.id)) return &artwork;
    return nullptr;
}

inline bool contains(const std::optional<std::string> &id) {
    return find(id) != nullptr || findArtwork(id) != nullptr;
}

inline void draw(Graphics &g, const std::optional<std::string> &id, juce::Rectangle<float> bounds) {
    if (const auto *icon = find(id)) {
        draw(g, *icon, bounds);
    } else if (const auto *artwork = findArtwork(id)) {
        const auto image = ImageCache::getFromFile(artwork->file);
        if (!image.isValid()) return;
        if (artwork->id == "png:Other/waveform") {
            const auto size = std::min(bounds.getWidth(), bounds.getHeight());
            bounds = bounds.withSizeKeepingCentre(size, size);
            Graphics::ScopedSaveState saved(g);
            Path shape;
            shape.addRoundedRectangle(bounds, 4.f);
            g.reduceClipRegion(shape);
            g.drawImage(image, bounds, RectanglePlacement::centred);
        } else g.drawImage(image, bounds, RectanglePlacement::centred);
    }
}
} // namespace catlive::trackIcons
