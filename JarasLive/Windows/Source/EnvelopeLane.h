#pragma once
#include "Automation.h"
#include "Session.h"
namespace catlive {
class EnvelopeLane final : public Component {
  public:
    EnvelopeLane(Session &s, ID track, var curve, std::function<float(double)> x,
                 std::function<double(float)> time, std::function<void(String)> report)
        : session(s), trackID(std::move(track)), envelope(std::move(curve)), xAt(std::move(x)),
          timeAt(std::move(time)), error(std::move(report)) {
        setWantsKeyboardFocus(true);
        setComponentID("envelopeLane");
        setMouseCursor(MouseCursor::CrosshairCursor);
    }
    void paint(Graphics &g) override {
        g.fillAll(theme::background.brighter(.03f));
        g.setColour(theme::line);
        g.drawHorizontalLine(0, 0.f, (float)getWidth());
        const auto points = list(get(envelope, "points"));
        AutomationProgram program;
        auto settings = object();
        auto visibleEnvelope=JSON::parse(JSON::toString(envelope,true));
        put(visibleEnvelope,"enabled",true);
        put(settings, "envelopes", Array<var>{visibleEnvelope});
        program.prepare(settings);
        if (program.curves.empty())
            return;
        const auto &curve = program.curves.front();
        Path path;
        for (int x = 0; x <= getWidth(); x += 2) {
            const float y = yAt(curve.value(timeAt((float)x)));
            if (x == 0)
                path.startNewSubPath(0, y);
            else
                path.lineTo((float)x, y);
        }
        g.setColour(flag(envelope, "enabled", true) ? theme::green : theme::secondary);
        g.strokePath(path, PathStrokeType(1.2f));
        for (const auto &point : points) {
            const float x = xAt(num(point, "time")), y = yAt(num(point, "value"));
            if (x < -6 || x > getWidth() + 6)
                continue;
            g.setColour(str(point, "id") == selected ? Colours::white : theme::green);
            g.fillEllipse(x - 3, y - 3, 6, 6);
        }
    }
    void mouseDown(const MouseEvent &e) override {
        grabKeyboardFocus();
        selected.clear();
        dragging = false;
        const auto points = list(get(envelope, "points"));
        for (const auto &point : points)
            if (std::abs(xAt(num(point, "time")) - e.position.x) < 8 &&
                std::abs(yAt(num(point, "value")) - e.position.y) < 9) {
                selected = str(point, "id");
                break;
            }
        if (e.mods.isPopupMenu()) {
            PopupMenu menu;
            menu.addItem(2,"Linear");menu.addItem(3,"Square");menu.addItem(4,"Smooth");menu.addItem(5,"Fast start");menu.addItem(6,"Fast end");
            menu.showMenuAsync(
                PopupMenu::Options().withTargetComponent(this),
                [safe = SafePointer<EnvelopeLane>(this)](int action) {
                    if (!safe)
                        return;
                    if (action >= 2 && action <= 6) {
                        auto points = list(get(safe->envelope, "points"));
                        static const char *shapes[]{"linear", "square", "smooth", "fastStart",
                                                    "fastEnd"};
                        for (auto &point : points)
                            if (str(point, "id") == safe->selected)
                                put(point, "shape", shapes[action - 2]);
                        put(safe->envelope, "points", points);
                        safe->commit();
                    }
                });
        }
        repaint();
    }
    void mouseDoubleClick(const MouseEvent &e) override {
        if (!e.mods.isPopupMenu() && selected.isEmpty())
            add(e.position, e.mods.isShiftDown());
    }
    void mouseDrag(const MouseEvent &e) override {
        if (selected.isEmpty() || e.mods.isPopupMenu())
            return;
        auto points = list(get(envelope, "points"));
        for (auto point : points)
            if (str(point, "id") == selected) {
                put(point, "time", snap(timeAt(e.position.x), e.mods.isShiftDown()));
                put(point, "value", valueAt(e.position.y));
                automation::insert(envelope, point);
                dragging = true;
                repaint();
                break;
            }
    }
    void mouseUp(const MouseEvent &) override {
        if (dragging) {
            dragging = false;
            commit();
        }
    }
    bool keyPressed(const KeyPress &key) override {
        if ((key == KeyPress::deleteKey || key == KeyPress::backspaceKey) &&
            selected.isNotEmpty()) {
            remove();
            return true;
        }
        return false;
    }

  private:
    Session &session;
    ID trackID;
    var envelope;
    String selected;
    bool dragging = false;
    std::function<float(double)> xAt;
    std::function<double(float)> timeAt;
    std::function<void(String)> error;
    float yAt(double value) const {
        return 4 + (getHeight() - 8) * (1 - (float)jlimit(0., 1., value));
    }
    double valueAt(float y) const {
        return jlimit(0., 1., 1 - (y - 4) / std::max(1., getHeight() - 8.));
    }
    double snap(double time, bool free) const {
        time = std::max(0., time);
        if (!free)
            if (auto *s = session.song())
                time = std::round(time / (60. / s->bpm / 4)) * (60. / s->bpm / 4);
        return time;
    }
    void add(Point<float> position, bool free) {
        auto point = object();
        selected = text(uuid());
        put(point, "id", selected);
        put(point, "time", snap(timeAt(position.x), free));
        put(point, "value", valueAt(position.y));
        put(point, "shape", "linear");
        automation::insert(envelope, point);
        commit();
    }
    void remove() {
        auto points = list(get(envelope, "points"));
        for (int i = points.size(); --i >= 0;)
            if (str(points[i], "id") == selected)
                points.remove(i);
        put(envelope, "points", points);
        selected.clear();
        commit();
    }
    void commit() {
        // A successful edit rebuilds timeline children; hold all data before entering Session.
        const auto curve = envelope.clone();
        const auto curveID = str(curve, "id");
        const auto target = trackID;
        auto report = error;
        try {
            session.edit([&](jaras::Project &p) {
                for (auto &s : p.songs)
                    for (auto &t : s.tracks)
                        if (t.id == target) {
                            auto settings = automation::settings(t);
                            auto points = list(get(settings, "envelopes"));
                            for (auto &entry : points)
                                if (str(entry, "id") == curveID)
                                    entry = curve;
                            put(settings, "envelopes", points);
                            t.automationJSON = utf8(JSON::toString(settings, true));
                        }
            });
        } catch (const std::exception &e) {
            if (report)
                report(String::fromUTF8(e.what()));
        }
    }
};
} // namespace catlive
