#pragma once
#include "ModalSheet.h"
namespace catlive {
class ConversionReportPanel final : public Component {
  public:
    explicit ConversionReportPanel(const String &message) {
        report.setMultiLine(true,true);report.setReadOnly(true);report.setScrollbarsShown(true);
        report.setPopupMenuEnabled(false);report.setText(message);report.setFont(theme::font(12));
        report.setColour(TextEditor::backgroundColourId,theme::background);
        report.setColour(TextEditor::outlineColourId,Colours::transparentBlack);
        addAndMakeVisible(report);addAndMakeVisible(close);
        close.onClick=[this]{ModalSheet::dismiss(*this);};
    }
    void resized() override {
        report.setBounds(getLocalBounds().reduced(18).withTrimmedBottom(38));
        close.setBounds(getWidth()-96,getHeight()-42,78,26);
    }
  private:
    TextEditor report;
    QuietButton close{"OK"};
};
}
