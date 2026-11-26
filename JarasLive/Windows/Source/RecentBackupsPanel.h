#pragma once
#include "ProjectBackups.h"

namespace catlive {
class RecentBackupsPanel final : public Component {
  public:
    RecentBackupsPanel(File document, std::function<void(File)> open) : openBackup(std::move(open)) {
        setComponentID("recentBackups");
        title.setText(localization::translate("Recent backups"), dontSendNotification);
        title.setFont(theme::semiboldFont(15));
        status.setText(localization::translate("Loading"), dontSendNotification);
        status.setFont(theme::font(13));
        addAndMakeVisible(title); addAndMakeVisible(status);
        viewport.setViewedComponent(&list, false);
        viewport.setScrollBarsShown(true, false);
        addAndMakeVisible(viewport);
        setSize(430, 110);
        // A project on a slow disk must not block the interface when opening this list.
        Thread::launch([safe = SafePointer<RecentBackupsPanel>(this), document] {
            std::vector<File> files; String error;
            try {
                if (document != File()) files = projectBackups::files(document);
                std::reverse(files.begin(), files.end());
                if (files.size() > 10) files.resize(10);
            } catch (const std::exception &e) { error = String::fromUTF8(e.what()); }
            MessageManager::callAsync([safe, files = std::move(files), error] {
                if (safe) safe->loaded(files, error);
            });
        });
    }
    ~RecentBackupsPanel() override { viewport.setViewedComponent(nullptr, false); }
    void resized() override {
        auto bounds = getLocalBounds().reduced(16);
        title.setBounds(bounds.removeFromTop(25)); bounds.removeFromTop(8);
        status.setBounds(bounds);
        viewport.setBounds(bounds);
        list.setSize(std::max(1, bounds.getWidth() - viewport.getScrollBarThickness()), (int)rows.size() * 56);
        for (size_t i = 0; i < rows.size(); ++i)
            rows[i]->setBounds(0, (int)i * 56, list.getWidth(), 51);
    }
  private:
    class Row final : public Button {
      public:
        explicit Row(const File &value) : Button(value.getFileName()), file(value), date(projectBackups::date(value).formatted("%d/%m/%Y %H:%M")) {
            setWantsKeyboardFocus(false);
        }
        void paintButton(Graphics &g, bool over, bool down) override {
            g.setColour(Colours::white.withAlpha(down ? .13f : over ? .09f : .05f));
            g.fillRoundedRectangle(getLocalBounds().toFloat(), 4);
            auto bounds = getLocalBounds().reduced(8, 5);
            g.setColour(Colours::white); g.setFont(theme::semiboldFont(13));
            g.drawText(file.getFileName(), bounds.removeFromTop(23), Justification::centredLeft, true);
            g.setColour(Colours::white.withAlpha(.55f)); g.setFont(theme::font(11));
            g.drawText(date, bounds, Justification::centredLeft, true);
        }
        File file; String date;
    };
    Label title, status;
    Viewport viewport;
    Component list;
    std::vector<std::unique_ptr<Row>> rows;
    std::function<void(File)> openBackup;
    void loaded(const std::vector<File> &files, const String &error) {
        status.setText(error.isNotEmpty() ? error : localization::translate("No backups found"), dontSendNotification);
        status.setVisible(files.empty()); viewport.setVisible(!files.empty());
        for (const auto &file : files) {
            auto row = std::make_unique<Row>(file);
            row->onClick = [safe = SafePointer<RecentBackupsPanel>(this), file] {
                if (!safe) return;
                auto open = safe->openBackup;
                if (auto *callout = safe->findParentComponentOfClass<CallOutBox>()) callout->dismiss();
                MessageManager::callAsync([open, file] { if (open) open(file); });
            };
            list.addAndMakeVisible(*row); rows.push_back(std::move(row));
        }
        setSize(430, 65 + (files.empty() ? 45 : std::min(410, (int)files.size() * 56)));
        resized(); repaint();
    }
};
}
