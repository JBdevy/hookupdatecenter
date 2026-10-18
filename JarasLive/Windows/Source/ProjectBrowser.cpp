#include "ProjectBrowser.h"
#include "InterfaceIcons.h"
namespace catlive {
void ProjectBrowser::Action::paintButton(Graphics &g, bool over, bool down) {
    g.setColour(theme::panel.brighter(down ? .12f : over ? .06f : 0.f));
    g.fillRoundedRectangle(getLocalBounds().toFloat(), 6);
    g.setColour(Colours::white);
    auto font = theme::mediumFont(12);
    g.setFont(font);
    const float textWidth = GlyphArrangement::getStringWidth(font, getName());
    float x = (getWidth() - textWidth - 24) * .5f, y = (getHeight() - 16) * .5f;
    Path path;
    if (icon == recording) {
        drawInterfaceIcon(g, "record", {x, y, 16, 16});
    } else if (icon == piano) {
        drawInterfaceIcon(g, "piano", {x, y, 16, 16});
    } else if (icon == folder || icon == plusFolder) {
        path.startNewSubPath(x, y + 3);
        path.lineTo(x + 6, y + 3);
        path.lineTo(x + 8, y + 5);
        path.lineTo(x + 16, y + 5);
        path.lineTo(x + 16, y + 14);
        path.lineTo(x, y + 14);
        path.closeSubPath();
    } else if (icon == waveform) {
        for (int i = 0; i < 6; ++i) {
            float h = (i == 2 || i == 3) ? 14.f : (i == 1 || i == 4) ? 9.f : 4.f;
            path.startNewSubPath(x + i * 3, y + 8 - h / 2);
            path.lineTo(x + i * 3, y + 8 + h / 2);
        }
    } else if (icon == back) {
        path.startNewSubPath(x + 8, y + 3);
        path.lineTo(x + 3, y + 8);
        path.lineTo(x + 8, y + 13);
        path.startNewSubPath(x + 3, y + 8);
        path.lineTo(x + 16, y + 8);
    } else {
        path.addRoundedRectangle(x + 1, y + 2, 14, 12, 1.5f);
    }
    if (icon == plusDocument || icon == plusFolder) {
        path.startNewSubPath(x + 8, y + 7);
        path.lineTo(x + 8, y + 12);
        path.startNewSubPath(x + 5.5f, y + 9.5f);
        path.lineTo(x + 10.5f, y + 9.5f);
    }
    if (icon == archive)
        for (int i = 0; i < 4; ++i)
            path.addRectangle(x + 7, y + 3 + i * 2.5f, 2, 1);
    g.strokePath(path, PathStrokeType(1.2f, PathStrokeType::curved, PathStrokeType::rounded));
    g.drawText(getName(), juce::Rectangle<float>(x + 24, 0, textWidth + 2, (float)getHeight()),
               Justification::centredLeft);
}
ProjectBrowser::ProjectBrowser() {
    setOpaque(true);
    for (auto *button :
         {&create, &add, &recent, &empty, &stems, &reaper, &logic, &recording, &package, &back}) {
        addAndMakeVisible(*button);
        button->setComponentID(button->getName());
    }
    addAndMakeVisible(browseButton);
    addAndMakeVisible(search);
    addAndMakeVisible(recents);
    create.onClick = [this] { selectMode(mode == creating ? none : creating); };
    add.onClick = [this] { selectMode(mode == adding ? none : adding); };
    recent.onClick = [this] { selectMode(opening); };
    empty.onClick = [this] {
        if (createEmpty)
            createEmpty();
    };
    reaper.onClick = [this] {
        if (createReaper)
            createReaper();
    };
    logic.onClick = [this] {
        if (createLogic)
            createLogic();
    };
    recording.onClick = [this] { if (createRecording) createRecording(); };
    stems.onClick = [this] {
        auto action = mode == adding ? addStems : createStems;
        if (action)
            action();
    };
    package.onClick = [this] {
        if (addPackage)
            addPackage();
    };
    browseButton.onClick = [this] {
        if (browse)
            browse();
    };
    back.onClick = [this] {
        if (resume)
            resume();
    };
    search.setTextToShowWhenEmpty("Buscar projetos recentes", theme::secondary);
    search.setFont(theme::font(12));
    search.setBorder(BorderSize<int>(9));
    search.setColour(TextEditor::outlineColourId, Colours::transparentBlack);
    search.onTextChange = [this] { refresh(); };
    recents.setModel(this);
    recents.setRowHeight(56);
    recents.setOutlineThickness(0);
    recents.setMultipleSelectionEnabled(false);
    refresh();
}
void ProjectBrowser::setProjectOpen(bool value) {
    projectOpen = value;
    resized();
}
void ProjectBrowser::selectMode(Mode value) {
    mode = value;
    refresh();
    resized();
    repaint();
}
void ProjectBrowser::refresh() {
    filtered.clear();
    for (auto &path : RecentProjects::read())
        if (search.getText().trim().isEmpty() || path.containsIgnoreCase(search.getText().trim()))
            filtered.add(path);
    recents.updateContent();
    repaint();
}
void ProjectBrowser::paint(Graphics &g) {
    g.fillAll(theme::background);
    g.setColour(Colours::white);
    g.setFont(theme::font(18, true));
    g.drawText("CatLive", 24, 24, getWidth() - 48, 20, Justification::centredLeft);
    if (mode == opening) {
        g.setFont(theme::font(11));
        g.setColour(theme::secondary);
        g.drawText("Projetos recentes", 24, 114, getWidth() - 150, 24, Justification::centredLeft);
        if (filtered.isEmpty())
            g.drawText("Nenhum projeto recente encontrado.", 24, 202, getWidth() - 48, 24,
                       Justification::centredLeft);
    }
}
void ProjectBrowser::resized() {
    int width = getWidth() - 48, cell = (width - 20) / 3;
    create.setBounds(24, 60, cell, 38);
    add.setBounds(34 + cell, 60, cell, 38);
    recent.setBounds(44 + 2 * cell, 60, width - 2 * cell - 20, 38);
    stems.setVisible(mode == creating || mode == adding);
    empty.setVisible(mode == creating);
    package.setVisible(mode == adding);
    reaper.setVisible(mode == creating);
    logic.setVisible(mode == creating);
    recording.setVisible(mode == creating);
    // ProjectBrowserView on macOS: three creation choices, then two imports.
    // These inner HStacks use an 8-point gap; the top navigation uses 10.
    if (mode == creating) {
        const int creationWidth = (width - 16) / 3;
        stems.setBounds(24, 114, creationWidth, 38);
        empty.setBounds(32 + creationWidth, 114, creationWidth, 38);
        recording.setBounds(40 + 2 * creationWidth, 114, width - 2 * creationWidth - 16, 38);
        const int importWidth = (width - 8) / 2;
        reaper.setBounds(24, 160, importWidth, 38);
        logic.setBounds(32 + importWidth, 160, width - importWidth - 8, 38);
    } else if (mode == adding) {
        const int optionWidth = (width - 10) / 2;
        stems.setBounds(24, 114, optionWidth, 38);
        package.setBounds(34 + optionWidth, 114, width - optionWidth - 10, 38);
    }
    browseButton.setVisible(mode == opening);
    search.setVisible(mode == opening);
    recents.setVisible(mode == opening);
    browseButton.setBounds(getWidth() - 100, 114, 76, 24);
    search.setBounds(24, 148, width, 35);
    recents.setBounds(24, 193, width, std::min(170, std::max(0, getHeight() - 249)));
    back.setVisible(projectOpen);
    back.setBounds(24, getHeight() - 52, 150, 28);
}
void ProjectBrowser::paintListBoxItem(int row, Graphics &g, int width, int height, bool selected) {
    if (!isPositiveAndBelow(row, filtered.size()))
        return;
    File file(filtered[row]);
    g.setColour(selected ? theme::panel.darker(.12f) : theme::panel);
    g.fillRect(0, 0, width, height - 6);
    g.setColour(selected ? Colours::white.darker(.18f) : Colours::white);
    g.setFont(theme::font(14, true));
    g.drawText(file.getFileNameWithoutExtension(), 10, 6, width - 40, 19,
               Justification::centredLeft);
    g.setColour(theme::secondary);
    g.setFont(theme::font(10));
    g.drawText(file.getParentDirectory().getFullPathName(), 10, 26, width - 40, 17,
               Justification::centredLeft);
    Path chevron;
    chevron.startNewSubPath((float)width - 20, 19);
    chevron.lineTo((float)width - 15, 24);
    chevron.lineTo((float)width - 20, 29);
    g.strokePath(chevron, PathStrokeType(1.3f));
}
void ProjectBrowser::returnKeyPressed(int row) {
    if (isPositiveAndBelow(row, filtered.size()) && open)
        open(File(filtered[row]));
}
void ProjectBrowser::listBoxItemClicked(int row, const MouseEvent &event) {
    if (!isPositiveAndBelow(row, filtered.size()))
        return;
    if (!event.mods.isPopupMenu()) {
        returnKeyPressed(row);
        return;
    }
    File file(filtered[row]);
    PopupMenu menu;
    const bool missing=!file.existsAsFile();
    menu.addItem(1,missing?"Remove from recents":"Delete project");
    menu.showMenuAsync(PopupMenu::Options().withTargetComponent(&recents),[safe=Component::SafePointer<ProjectBrowser>(this),file,missing](int result){
        if(!safe || result!=1)return;
        if(missing){RecentProjects::forget(file);safe->refresh();}
        else if(safe->deleteProject)safe->deleteProject(file);
    });
}
} // namespace catlive
