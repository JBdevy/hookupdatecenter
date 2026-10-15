#pragma once
#include "Session.h"
#include "ModalSheet.h"
namespace catlive {
class PatchPanel final : public Component {
  public:
    PatchPanel(Session &s, ID target, std::function<void(String)> report)
        : session(s), id(std::move(target)), error(std::move(report)) {
        addAndMakeVisible(viewport);
        viewport.setViewedComponent(&content, false);
        viewport.setScrollBarsShown(true, false);
        addAndMakeVisible(close);
        close.onClick = [this] { ModalSheet::dismiss(*this); };
        build();
    }
    void paint(Graphics &g) override { g.fillAll(theme::background); }
    void resized() override {
        viewport.setBounds(20, 0, getWidth() - 40, getHeight() - 48);
        content.setSize(std::max(300, viewport.getWidth() - 10), height);
        close.setBounds(getWidth() / 2 - 36, getHeight() - 38, 72, 26);
    }

  private:
    Session &session;
    ID id;
    std::function<void(String)> error;
    Viewport viewport;
    Component content;
    OwnedArray<Component> fields;
    TextButton close{"Fechar"};
    int height = 0;
    const jaras::Track *track() const {
        if (auto *song = session.song())
            for (const auto &t : song->tracks)
                if (t.id == id)
                    return &t;
        return nullptr;
    }
    void edit(std::function<void(jaras::Track &)> action) {
        try {
            session.edit([&](jaras::Project &p) {
                for (auto &s : p.songs)
                    for (auto &t : s.tracks)
                        if (t.id == id)
                            action(t);
            });
        } catch (const std::exception &e) {
            if (error)
                error(String::fromUTF8(e.what()));
        }
        MessageManager::callAsync([safe = SafePointer<PatchPanel>(this)] {
            if (safe)
                safe->build();
        });
    }
    void label(String text, int x, int y, int width, bool bold = false) {
        auto *label = new Label();
        fields.add(label);
        content.addAndMakeVisible(label);
        label->setText(localization::translate(text), dontSendNotification);
        label->setFont(bold ? theme::semiboldFont(12) : theme::font(12));
        label->setBounds(x, y, width, 24);
    }
    ComboBox &choice(int x, int y, int width, const StringArray &items, int selected,
                     std::function<void(int)> changed) {
        auto *box = new ComboBox();
        fields.add(box);
        content.addAndMakeVisible(box);
        box->getProperties().set("preserveNames", true);
        box->addItemList(items, 1);
        box->setSelectedId(selected, dontSendNotification);
        box->setBounds(x, y, width, 26);
        box->onChange = [box, changed] { changed(box->getSelectedId()); };
        return *box;
    }
    void button(String name, int x, int y, int width, std::function<void()> clicked) {
        auto *b = new TextButton(name);
        fields.add(b);
        content.addAndMakeVisible(b);
        b->setBounds(x, y, width, 24);
        b->getProperties().set("flat", true);
        b->onClick = std::move(clicked);
    }
    void build() {
        fields.clear();
        const auto *t = track();
        if (!t)
            return;
        auto *device = session.audio.devices.getCurrentAudioDevice();
        label(device ? device->getName() : String::fromUTF8("Áudio não iniciado"), 0, 8, 300);
        StringArray inputs{"Nenhum"};
        std::vector<jaras::OutputPatch> inputPatches{{-1, 1}};
        const auto inputNames = device ? device->getInputChannelNames() : StringArray();
        for (int i = 0; i < inputNames.size(); ++i) {
            inputs.add(String(i + 1) + " — " + inputNames[i]);
            inputPatches.push_back({i + 1, 1});
        }
        for (int i = 0; i + 1 < inputNames.size(); i += 2) {
            inputs.add(String(i + 1) + " / " + String(i + 2) + " — Stereo");
            inputPatches.push_back({i + 1, 2});
        }
        int selected = 1;
        if (t->inputPatch)
            for (size_t i = 0; i < inputPatches.size(); ++i)
                if (inputPatches[i].firstChannel == t->inputPatch->firstChannel &&
                    inputPatches[i].channelCount == t->inputPatch->channelCount)
                    selected = (int)i + 1;
        label("Entrada", 0, 44, 62);
        choice(66, 44, 234, inputs, selected, [this, inputPatches](int n) {
            edit([&](auto &t) {
                if (n > 1)
                    t.inputPatch = inputPatches[(size_t)n - 1];
                else
                    t.inputPatch.reset();
            });
        });
        label("Entrada MIDI", 0, 80, 194);
        label("Canal MIDI", 208, 80, 92);
        StringArray midi{"Nenhum", "MIDI 1", "MIDI 2", "MIDI 3"};
        choice(0, 108, 196, midi, t->midiInput.value_or(0)+1, [this](int n) {
            edit([&](auto &t) {
                if (n > 1)
                    t.midiInput = n - 1;
                else
                    t.midiInput.reset();
            });
        });
        StringArray channels{"Todos"};
        for (int i = 1; i <= 16; ++i)
            channels.add(String(i));
        choice(208, 108, 92, channels, t->midiChannel.value_or(0) + 1,
               [this](int n) { edit([&](auto &t) { if(n>1)t.midiChannel=n-1;else t.midiChannel.reset(); }); });
        auto outputs = t->outputPatches();
        label("Saída", 0, 148, 200, true);
        button("+", 264, 148, 36, [this] {
            edit([](auto &t) {
                auto outputs = t.outputPatches();
                outputs.push_back({0, 2});
                t.outputs = outputs;
                t.patch.reset();
                t.secondaryPatch.reset();
            });
        });
        StringArray destinations{"Master", "Nenhum"};
        std::vector<jaras::OutputPatch> patches{{0, 2}, {-1, 2}};
        if (t->parentTrackID) {
            destinations.add("Master Group");
            patches.push_back({-2, 2});
        }
        const int outputCount = std::max(2, device ? device->getOutputChannelNames().size() : 2);
        for (int i = 1; i <= outputCount; ++i) {
            destinations.add("Out " + String(i));
            patches.push_back({i, 1});
        }
        for (int i = 1; i < outputCount; i += 2) {
            destinations.add("Out " + String(i) + " / " + String(i + 1));
            patches.push_back({i, 2});
        }
        int y = 182;
        for (size_t row = 0; row < outputs.size(); ++row) {
            const auto patch = outputs[row];
            int selected = 0;
            for (size_t p = 0; p < patches.size(); ++p)
                if (patch.firstChannel == patches[p].firstChannel &&
                    patch.channelCount == patches[p].channelCount)
                    selected = (int)p + 1;
            if (selected == 0) {
                destinations.add(String(patch.firstChannel) + " / " +
                                 String(patch.firstChannel + patch.channelCount - 1) +
                                 String::fromUTF8(" — Indisponível"));
                patches.push_back(patch);
                selected = (int)patches.size();
            }
            choice(0, y, 244, destinations, selected, [this, row, patches](int n) {
                edit([&](auto &t) {
                    auto outputs = t.outputPatches();
                    if (row < outputs.size())
                        outputs[row] = patches[(size_t)n - 1];
                    t.outputs = outputs;
                    t.patch.reset();
                    t.secondaryPatch.reset();
                });
            });
            button(String::fromUTF8("⊖"), 264, y, 36, [this, row] {
                edit([&](auto &t) {
                    auto outputs = t.outputPatches();
                    if (row < outputs.size())
                        outputs.erase(outputs.begin() + row);
                    t.outputs = outputs;
                    t.patch.reset();
                    t.secondaryPatch.reset();
                });
            });
            y += 34;
        }
        if (jaras::fixedTrackName(t->role).empty())
            for (bool receive : {true, false}) {
                y += 12;
                label(receive ? "Recebimento" : "Envio", 0, y, 244, true);
                button("+", 264, y, 36, [this, receive] {
                    edit([&](auto &t) {
                        if (!t.routing)
                            t.routing = jaras::TrackRouting{{}, {}};
                        auto &routes = receive ? t.routing->receives : t.routing->transmitters;
                        routes.push_back({});
                    });
                });
                y += 34;
                const auto routes =
                    t->routing ? (receive ? t->routing->receives : t->routing->transmitters)
                               : std::vector<std::optional<ID>>();
                StringArray names{"Nenhum"};
                std::vector<ID> ids{ID{}};
                if (auto *song = session.song())
                    for (const auto &other : song->tracks)
                        if (other.id != id && jaras::fixedTrackName(other.role).empty()) {
                            names.add(text(other.name));
                            ids.push_back(other.id);
                        }
                for (size_t row = 0; row < routes.size(); ++row) {
                    int selected = 1;
                    for (size_t i = 1; i < ids.size(); ++i)
                        if (routes[row] && *routes[row] == ids[i])
                            selected = (int)i + 1;
                    choice(0, y, 244, names, selected, [this, receive, row, ids](int n) {
                        edit([&](auto &t) {
                            if (!t.routing)
                                return;
                            auto &routes = receive ? t.routing->receives : t.routing->transmitters;
                            if (row < routes.size())
                                routes[row] =
                                    n > 1 ? std::optional<ID>(ids[(size_t)n - 1]) : std::nullopt;
                        });
                    });
                    button(String::fromUTF8("⊖"), 264, y, 36, [this, receive, row] {
                        edit([&](auto &t) {
                            if (!t.routing)
                                return;
                            auto &routes = receive ? t.routing->receives : t.routing->transmitters;
                            if (row < routes.size())
                                routes.erase(routes.begin() + row);
                        });
                    });
                    y += 34;
                }
            }
        height = y + 16;
        resized();
    }
};
} // namespace catlive
