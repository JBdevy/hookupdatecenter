#pragma once
#include "ActionBindings.h"
#include "ModalSheet.h"

namespace catlive {
class SetlistBlockMIDIPanel final : public Component, private ChangeListener {
  public:
    SetlistBlockMIDIPanel(ActionBindings &bindings, int number)
        : actions(bindings), action(setlistBlockAction(number)), title(setlistBlockActionTitle(number)) {
        setComponentID("setlistBlockMIDIPanel");
        setWantsKeyboardFocus(true);
        for (auto *control : std::initializer_list<Component *>{&heading, &instruction, &mapping, &remove, &feedback, &cancel, &save})
            addAndMakeVisible(control);
        heading.setText(title, dontSendNotification); heading.setFont(theme::semiboldFont(14));
        instruction.setText(localization::translate("Press a MIDI note or controller button."), dontSendNotification);
        instruction.setFont(theme::font(12)); feedback.setFont(theme::font(12));
        mapping.setColour(Label::backgroundColourId, theme::display);
        mapping.setFont(theme::font(14)); mapping.setJustificationType(Justification::centred);
        mapping.setComponentID("setlistBlockMIDICandidate");
        remove.setComponentID("setlistBlockMIDIRemove");
        cancel.setComponentID("setlistBlockMIDICancel"); save.setComponentID("setlistBlockMIDISave");
        remove.setButtonText(localization::translate("Remove mapping"));
        cancel.setButtonText(localization::translate("Cancel")); save.setButtonText(localization::translate("Save"));
        save.setColour(TextButton::buttonColourId, theme::green);
        remove.onClick = [this] { if (actions.assign(action, "midi", {})) ModalSheet::dismiss(*this); else refresh(); };
        cancel.onClick = [this] { ModalSheet::dismiss(*this); };
        save.onClick = [this] { commit(false); };
        actions.addChangeListener(this);
        actions.beginMIDICandidate(action, [self=SafePointer<SetlistBlockMIDIPanel>(this)](var input) {
            if (self && !self->confirming) { self->candidate = std::move(input); self->actions.error.clear(); self->refresh(); }
        });
        candidate = actions.midiInput(action).clone();
        refresh();
    }
    ~SetlistBlockMIDIPanel() override {
        actions.removeChangeListener(this);
        if (actions.learning == action) actions.cancel();
    }
    bool keyPressed(const KeyPress &key) override {
        if (key == KeyPress::returnKey && candidate.isObject()) { commit(false); return true; }
        return false;
    }
    void resized() override {
        auto bounds = getLocalBounds().reduced(18);
        heading.setBounds(bounds.removeFromTop(24)); instruction.setBounds(bounds.removeFromTop(28));
        mapping.setBounds(bounds.removeFromTop(36)); bounds.removeFromTop(6);
        feedback.setBounds(bounds.removeFromTop(30)); remove.setBounds(bounds.removeFromTop(28));
        cancel.setBounds(18, getHeight()-44, 100, 28); save.setBounds(getWidth()-118, getHeight()-44, 100, 28);
    }
  private:
    ActionBindings &actions;
    String action, title;
    var candidate;
    bool confirming = false;
    Label heading, instruction, mapping, feedback;
    TextButton remove, cancel, save;
    void changeListenerCallback(ChangeBroadcaster *) override { refresh(); }
    void commit(bool replace) {
        if (!candidate.isObject() || confirming) return;
        if (actions.assign(action, "midi", candidate.clone(), replace)) { ModalSheet::dismiss(*this); return; }
        const auto conflict = actions.midiConflict(action, candidate);
        if (conflict.isEmpty() || replace) { refresh(); return; }
        auto message = localization::translate("%@ is already mapped to %@. Remove it from that function and use it for %@?");
        for (const auto &value : {ActionBindings::midiLabel(candidate), conflict, title}) {
            const int at = message.indexOf("%@");
            if (at >= 0) message = message.replaceSection(at, 2, value);
        }
        confirming = true;
        AlertWindow::showOkCancelBox(MessageBoxIconType::QuestionIcon,
            localization::translate("This control is already mapped."), message,
            localization::translate("Transfer mapping"), localization::translate("Cancel"), this,
            ModalCallbackFunction::create([self=SafePointer<SetlistBlockMIDIPanel>(this)](int result) {
                if (self) { self->confirming = false; if (result) self->commit(true); }
            }));
    }
    void refresh() {
        const auto label = ActionBindings::midiLabel(candidate);
        mapping.setText(label.isEmpty() ? String::fromUTF8("—") : label, dontSendNotification);
        remove.setVisible(actions.midiInput(action).isObject()); save.setEnabled(candidate.isObject());
        feedback.setText(actions.error, dontSendNotification);
        feedback.setColour(Label::textColourId, Colour(0xffff6565));
    }
};
}
