#pragma once
#include "Common.h"
#include <BinaryData.h>
namespace catlive {
namespace localization {
inline bool english = false;
inline String translate(const String &original) {
    if(original=="BLOCOS" || original=="BLOCKS")return english?"BLOCKS":"BLOCOS";
    if (original == "Setlist")
        return original;
    struct Catalog {
        std::map<String, String> english, portuguese;
        Catalog() {
            const auto en = JSON::parse(
                String::fromUTF8(BinaryData::English_json, BinaryData::English_jsonSize));
            const auto pt = JSON::parse(
                String::fromUTF8(BinaryData::Portuguese_json, BinaryData::Portuguese_jsonSize));
            if (auto *dictionary = pt.getDynamicObject())
                for (const auto &entry : dictionary->getProperties()) {
                    const auto key = entry.name.toString(), translated = entry.value.toString(),
                               other = str(en, entry.name, key);
                    english[key] = other;
                    english[translated] = other;
                    english[other] = other;
                    portuguese[key] = translated;
                    portuguese[other] = translated;
                    portuguese[translated] = translated;
                }
        }
    };
    static const Catalog catalog;
    const auto &map = english ? catalog.english : catalog.portuguese;
    const auto found = map.find(original);
    return found == map.end() ? original : found->second;
}
// Apply only to interface-owned panels, never to song/track names or media fields.
inline void panel(Component &component) {
    if (auto *label = dynamic_cast<Label *>(&component))
        label->setText(localization::translate(label->getText()), dontSendNotification);
    if (auto *button = dynamic_cast<TextButton *>(&component))
        button->setButtonText(localization::translate(button->getButtonText()));
    if (auto *button = dynamic_cast<ToggleButton *>(&component))
        button->setButtonText(localization::translate(button->getButtonText()));
    if (auto *combo = dynamic_cast<ComboBox *>(&component)) {
        if (!(bool)combo->getProperties().getWithDefault("preserveNames", false))
            for (int i = 0; i < combo->getNumItems(); ++i)
                combo->changeItemText(combo->getItemId(i),
                                      localization::translate(combo->getItemText(i)));
    }
    for (auto *child : component.getChildren())
        panel(*child);
}
} // namespace localization
} // namespace catlive
