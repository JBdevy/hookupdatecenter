#pragma once
#include "Common.h"

namespace catlive {
// Paths are local preferences. Project documents remain portable between platforms.
struct RecentProjects {
    static File storage() {
        return File::getSpecialLocation(File::userApplicationDataDirectory)
            .getChildFile("Hook Developer/CatLive/recent-projects.json");
    }
    static StringArray read() {
        StringArray paths;
        for (const auto &value : list(JSON::parse(storage())))
            if (File::isAbsolutePath(value.toString()))
                paths.addIfNotAlreadyThere(value.toString());
        return paths;
    }
    static void write(const StringArray &paths) {
        Array<var> values;
        for (int i = 0; i < std::min(20, paths.size()); ++i)
            values.add(paths[i]);
        auto file = storage();
        file.getParentDirectory().createDirectory();
        file.replaceWithText(JSON::toString(var(values)));
    }
    static void remember(const File &file) {
        auto paths = read();
        paths.removeString(file.getFullPathName(), true);
        paths.insert(0, file.getFullPathName());
        write(paths);
    }
    static void forget(const File &file) {
        auto paths = read();
        paths.removeString(file.getFullPathName(), true);
        write(paths);
    }
};

class ProjectBrowser final : public Component, private ListBoxModel, private Timer {
  public:
    ProjectBrowser();
    void paint(Graphics &) override;
    void resized() override;
    void refresh();
    std::function<void()> createEmpty, createStems, createReaper, createLogic, createRecording, addStems, addPackage,
        browse, resume;
    std::function<void(File)> open, openInNewTab, deleteProject;
    void setProjectOpen(bool);
    void setPlaybackRunning(bool value) { playbackRunning = value; updateEnabled(); }
    void beginLoading(const File &);
    void updateLoading(const String &);
    void finishLoading(const String &error = {});
    bool isLoading() const { return loading; }
    String loadingMessage() const { return loadingStatus.getText(); }
    String loadingFailure() const { return loadingError.getText(); }

  private:
    class Action final : public Button {
      public:
        enum Icon { document, plusDocument, folder, plusFolder, waveform, archive, back, piano, recording };
        Action(String title, Icon symbol) : Button(title), icon(symbol) {}
        void paintButton(Graphics &, bool, bool) override;

      private:
        Icon icon;
    };
    Action create{"Criar projeto", Action::plusDocument};
    Action add{"Adicionar ao projeto", Action::plusFolder};
    Action recent{"Projetos Recentes", Action::folder};
    Action empty{"Vazio", Action::document};
    Action stems{"Adicionar stems", Action::waveform};
    Action reaper{"REAPER", Action::waveform};
    Action logic{"Logic", Action::piano};
    Action recording{"REC Multitrack", Action::recording};
    Action package{"Add .ziplive", Action::archive};
    Action back{"Voltar ao projeto", Action::back};
    TextButton browseButton{String::fromUTF8("Procurar…")};
    TextEditor search;
    ListBox recents;
    Label loadingStatus, loadingError;
    juce::Rectangle<int> spinnerBounds;
    StringArray filtered;
    enum Mode { none, creating, adding, opening } mode = none;
    bool projectOpen = false, playbackRunning = false;
    bool loading = false;
    int getNumRows() override { return filtered.size(); }
    void paintListBoxItem(int, Graphics &, int, int, bool) override;
    void listBoxItemClicked(int, const MouseEvent &) override;
    void returnKeyPressed(int) override;
    void selectMode(Mode);
    void updateEnabled();
    void timerCallback() override { repaint(spinnerBounds); }
};
} // namespace catlive
