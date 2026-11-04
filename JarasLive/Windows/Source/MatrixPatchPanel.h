#pragma once
#include "Session.h"
#include "Localization.h"
#include "../../Core/Project/MatrixPatch.hpp"

namespace catlive {
class MatrixPatchPanel final : public Component, private Timer {
    static constexpr int rowHeight = 32, columnWidth = 38, labelWidth = 236, headerHeight = 170, top = 84;
    struct Row {
        ID id; String name, number; Colour color; bool sends = false, master = false;
        std::vector<jaras::OutputPatch> outputs; std::set<ID> destinations;
    };
    struct Column {
        ID track; jaras::OutputPatch output; String name, badge; Colour color; bool available = true;
    };
    class Body final : public Component {
        MatrixPatchPanel& owner;
      public:
        explicit Body(MatrixPatchPanel& panel) : owner(panel) {}
        void paint(Graphics& g) override { owner.paintCells(g); }
        void mouseMove(const MouseEvent& e) override { owner.move(e.position, e.getEventRelativeTo(&owner).position); }
        void mouseEnter(const MouseEvent& e) override { mouseMove(e); }
        void mouseExit(const MouseEvent&) override { owner.clearHover(); }
        void mouseDown(const MouseEvent& e) override {
            if (e.mods.isLeftButtonDown()) owner.toggle((int)e.position.y / rowHeight, (int)e.position.x / columnWidth);
        }
    } body{*this};
    class Scroller final : public Viewport {
        MatrixPatchPanel& owner;
      public:
        explicit Scroller(MatrixPatchPanel& panel) : owner(panel) {}
        void visibleAreaChanged(const juce::Rectangle<int>&) override { owner.clearHover(); owner.repaint(); }
    } viewport{*this};
    class Tip final : public Component {
      public:
        String label;
        Tip() { setInterceptsMouseClicks(false, false); }
        void paint(Graphics& g) override {
            const auto bounds = getLocalBounds().toFloat().reduced(.5f);
            g.setColour(Colour(0xf0262626)); g.fillRoundedRectangle(bounds,5);
            g.setColour(Colour(0xff777777)); g.drawRoundedRectangle(bounds,5,1);
            g.setFont(theme::semiboldFont(12)); g.setColour(Colours::white);
            g.drawText(label,getLocalBounds().reduced(6,0),Justification::centred,true);
        }
    } tip;
    Session& session;
    TextEditor search;
    std::vector<Row> rows;
    std::vector<Column> columns;
    ID songID;
    uint64 lastRevision = std::numeric_limits<uint64>::max();
    String lastDevice, failure;
    int hotRow = -1, hotColumn = -1, left = labelWidth;
    Colour activeColor{0xff68df97};
    String deviceDescription() const {
        auto* device = session.audio.devices.getCurrentAudioDevice();
        return device ? device->getName() + "\n" + device->getOutputChannelNames().joinIntoString("\n") : String();
    }
    bool enabled(int row, int col) const {
        const auto& r = rows[(size_t)row]; const auto& c = columns[(size_t)col];
        if (!c.track.empty()) return r.sends && r.id != c.track;
        return c.available && (c.output.firstChannel > 0 || r.master);
    }
    bool active(int row, int col) const {
        const auto& r = rows[(size_t)row]; const auto& c = columns[(size_t)col];
        return c.track.empty() ? jaras::matrixPatch::contains(r.outputs,c.output) : r.destinations.count(c.track) != 0;
    }
    void timerCallback() override {
        if (!isShowing()) return;
        if (lastRevision != session.revision || lastDevice != deviceDescription() || songID != (session.song() ? session.song()->id : ID{})) refresh();
    }
    void refresh() {
        lastRevision = session.revision; lastDevice = deviceDescription();
        const auto* song = session.song(); songID = song ? song->id : ID{};
        rows.clear(); columns.clear(); clearHover();
        const auto& project = session.project();
        auto masterOutputs = project.masterOutputs.value_or(std::vector<jaras::OutputPatch>{project.masterPatch.value_or(jaras::OutputPatch{1,2})});
        if (!project.masterOutputs && project.masterSecondaryPatch) masterOutputs.push_back(*project.masterSecondaryPatch);
        rows.push_back({{},"Master","M",activeColor,false,false,masterOutputs,{}});
        std::map<ID,std::set<ID>> destinations;
        if (song) for (const auto& t : song->tracks) {
            if (t.routing) {
                for (const auto& id : t.routing->transmitters) if(id)destinations[t.id].insert(*id);
                for (const auto& id : t.routing->receives) if(id)destinations[*id].insert(t.id);
            }
            if (t.parentTrackID && jaras::matrixPatch::contains(t.outputPatches(),{-2,2})) destinations[t.id].insert(*t.parentTrackID);
        }
        if (song) for (size_t i=0;i<song->tracks.size();++i) {
            const auto& t=song->tracks[i];
            if (!jaras::fixedTrackName(t.role).empty() && t.role.id!="generatedClick") continue;
            rows.push_back({t.id,text(t.name),String((int)i+1),Colour(0xff000000|t.color.value_or(0x888888)),
                jaras::fixedTrackName(t.role).empty() && t.role.id!="vinhetas",t.role.id!="vinhetas",t.outputPatches(),destinations[t.id]});
        }
        columns.push_back({{},{0,2},"Master","M",activeColor,true});
        auto* device=session.audio.devices.getCurrentAudioDevice();
        const auto names=device?device->getOutputChannelNames():StringArray{};
        std::vector<jaras::OutputPatch> patches;
        for(int c=1;c<=names.size();c+=2) {
            if(c<names.size())patches.push_back({c,2});
            patches.push_back({c,1});if(c<names.size())patches.push_back({c+1,1});
        }
        for(const auto& row:rows) for(auto patch:row.outputs)
            if(patch.firstChannel>0 && !jaras::matrixPatch::contains(patches,patch))patches.push_back(patch);
        auto channelName=[&](int channel){return channel>0 && channel<=names.size()?names[channel-1]:"Out "+String(channel);};
        for(auto patch:patches) {
            const bool available=patch.firstChannel+patch.channelCount-1<=names.size();
            String name=channelName(patch.firstChannel),badge=String(patch.firstChannel);
            if(patch.channelCount==2){name+=" / "+channelName(patch.firstChannel+1);badge+="+"+String(patch.firstChannel+1);}
            if(!available)name+=String::fromUTF8(" · ")+localization::translate("Unavailable");
            columns.push_back({{},patch,name,badge,Colour(0xff67b9ee),available});
        }
        if(song)for(size_t i=0;i<song->tracks.size();++i) {
            const auto& t=song->tracks[i];
            if(jaras::fixedTrackName(t.role).empty() && t.role.id!="vinhetas")
                columns.push_back({t.id,{},text(t.name),String((int)i+1),Colour(0xff000000|t.color.value_or(0x888888)),true});
        }
        const auto query=search.getText().trim();
        if(query.isNotEmpty())rows.erase(std::remove_if(rows.begin(),rows.end(),[&](const Row& row){return !row.name.containsIgnoreCase(query) && row.number!=query;}),rows.end());
        body.setSize(std::max(viewport.getMaximumVisibleWidth(),(int)columns.size()*columnWidth),std::max(viewport.getMaximumVisibleHeight(),(int)rows.size()*rowHeight));
        body.repaint();repaint();
    }
    void toggle(int row,int col) {
        if(row<0||col<0||row>=(int)rows.size()||col>=(int)columns.size()||(!enabled(row,col)&&!active(row,col)))return;
        if(!session.song()||session.song()->id!=songID){refresh();return;}
        const auto source=rows[(size_t)row].id;
        const auto destination=columns[(size_t)col];
        failure.clear();
        try {
            session.editTrackSettings([&](jaras::Project& project){
                if(source.empty()) {
                    auto outputs=project.masterOutputs.value_or(std::vector<jaras::OutputPatch>{project.masterPatch.value_or(jaras::OutputPatch{1,2})});
                    if(!project.masterOutputs && project.masterSecondaryPatch)outputs.push_back(*project.masterSecondaryPatch);
                    project.masterOutputs=jaras::matrixPatch::toggled(outputs,destination.output);project.masterPatch.reset();project.masterSecondaryPatch.reset();return;
                }
                for(auto& song:project.songs)if(song.id==songID){
                    if(!destination.track.empty())jaras::matrixPatch::toggleConnection(song,source,destination.track);
                    else for(auto& track:song.tracks)if(track.id==source){track.outputs=jaras::matrixPatch::toggled(track.outputPatches(),destination.output);track.patch.reset();track.secondaryPatch.reset();}
                }
            },true);
        } catch(const std::exception& e){failure=localization::translate(String::fromUTF8(e.what()));}
        refresh();
    }
    void clearHover() {hotRow=hotColumn=-1;tip.setVisible(false);body.repaint();repaint();}
    void move(Point<float> position,Point<float> inPanel) {
        const int r=(int)position.y/rowHeight,c=(int)position.x/columnWidth;
        if(r<0||c<0||r>=(int)rows.size()||c>=(int)columns.size()){clearHover();return;}
        if(hotRow!=r||hotColumn!=c){hotRow=r;hotColumn=c;body.repaint();repaint();}
        tip.label=rows[(size_t)r].name+" > "+columns[(size_t)c].name;
        const int width=std::min(getWidth()-8,std::max(96,roundToInt(GlyphArrangement::getStringWidth(theme::semiboldFont(12),tip.label))+18));
        tip.setBounds(juce::Rectangle<int>((int)inPanel.x+12,(int)inPanel.y-30,width,24).constrainedWithin(getLocalBounds().reduced(4)));
        tip.setVisible(true);tip.toFront(false);tip.repaint();
    }
    void paintCells(Graphics& g) {
        g.fillAll(Colour(0xff131416));
        const auto clip=g.getClipBounds();
        for(int row=std::max(0,clip.getY()/rowHeight);row<std::min((int)rows.size(),clip.getBottom()/rowHeight+1);++row){
            g.setColour(Colours::white.withAlpha(row==hotRow?.07f:row%2==0?.025f:0.f));g.fillRect(clip.getX(),row*rowHeight,clip.getWidth(),rowHeight);
            for(int col=std::max(0,clip.getX()/columnWidth);col<std::min((int)columns.size(),clip.getRight()/columnWidth+1);++col){
                if(col==hotColumn){g.setColour(Colour(0xff5985c2).withAlpha(.12f));g.fillRect(col*columnWidth,row*rowHeight,columnWidth,rowHeight);}
                auto cell=juce::Rectangle<float>((float)(col*columnWidth+5),(float)(row*rowHeight+5),(float)(columnWidth-10),(float)(rowHeight-10));
                if(active(row,col)){
                    g.setColour(activeColor);g.fillRoundedRectangle(cell,5);g.setColour(Colours::black);
                    Path tick;tick.startNewSubPath(cell.getCentreX()-5,cell.getCentreY());tick.lineTo(cell.getCentreX()-1,cell.getCentreY()+4);tick.lineTo(cell.getCentreX()+6,cell.getCentreY()-4);g.strokePath(tick,PathStrokeType(1.8f));
                }else if(enabled(row,col)){
                    g.setColour(Colours::white.withAlpha(col==hotColumn?.11f:.035f));g.fillRoundedRectangle(cell,5);
                    g.setColour(Colours::white.withAlpha(.1f));g.drawRoundedRectangle(cell,5,.5f);
                }else {g.setColour(Colours::white.withAlpha(.12f));g.drawLine(cell.getCentreX()-3,cell.getCentreY()+3,cell.getCentreX()+3,cell.getCentreY()-3);}
                if(row==hotRow&&col==hotColumn){g.setColour(activeColor);g.drawRoundedRectangle(cell,5,1.4f);}
            }
        }
    }
  public:
    explicit MatrixPatchPanel(Session& value):session(value){
        addAndMakeVisible(viewport);viewport.setViewedComponent(&body,false);viewport.setScrollBarsShown(true,true);viewport.setScrollBarThickness(6);
        addAndMakeVisible(search);search.setTextToShowWhenEmpty(localization::translate("Search tracks"),Colours::grey);search.setFont(theme::font(13));
        search.setColour(TextEditor::backgroundColourId,Colour(0xff141517));search.onTextChange=[this]{refresh();};
        addChildComponent(tip);refresh();startTimerHz(5);
    }
    ~MatrixPatchPanel() override {stopTimer();viewport.setViewedComponent(nullptr,false);}
    void resized() override {
        left=std::min(labelWidth,std::max(120,roundToInt(getWidth()*.3f)));
        search.setBounds(std::max(left,getWidth()-246),22,226,32);
        viewport.setBounds(left,top+headerHeight,std::max(0,getWidth()-left-16),std::max(0,getHeight()-top-headerHeight-44));
        body.setSize(std::max(viewport.getMaximumVisibleWidth(),(int)columns.size()*columnWidth),std::max(viewport.getMaximumVisibleHeight(),(int)rows.size()*rowHeight));
    }
    void paint(Graphics& g) override {
        g.fillAll(Colour(0xff1e1f21));g.setColour(Colours::white);g.setFont(theme::semiboldFont(22));g.drawText("Matrix Patch",20,16,std::max(1,search.getX()-36),28,Justification::centredLeft);
        auto* device=session.audio.devices.getCurrentAudioDevice();g.setFont(theme::font(12));g.setColour(Colours::grey);
        g.drawText(device?device->getName():localization::translate("No output device"),20,48,std::max(1,search.getX()-36),20,Justification::centredLeft);
        g.drawText(localization::translate("Sources"),28,top+headerHeight-30,left-40,24,Justification::centredLeft);
        g.drawText(localization::translate(String::fromUTF8("Destinations →")),28,top+12,left-40,24,Justification::centredLeft);
        const int xOffset=viewport.getViewPositionX(),yOffset=viewport.getViewPositionY();
        {
            Graphics::ScopedSaveState state(g);g.reduceClipRegion(left,top,viewport.getWidth(),headerHeight);
            for(int col=0;col<(int)columns.size();++col){const int x=left+col*columnWidth-xOffset; if(x+columnWidth<left||x>=viewport.getRight())continue;
                const auto& c=columns[(size_t)col];
                if(col==hotColumn){g.setColour(Colours::white.withAlpha(.07f));g.fillRect(x,top,columnWidth,headerHeight);}
                g.setColour(c.color);g.fillRect(x+6,top+headerHeight-5,columnWidth-12,2);g.setFont(theme::semiboldFont(12));g.drawText(c.badge,x+6,top+headerHeight-26,columnWidth-6,18,Justification::centredLeft);
                Graphics::ScopedSaveState rotated(g);g.addTransform(AffineTransform::rotation(-MathConstants<float>::halfPi).translated((float)x+10,(float)(top+headerHeight-34)));
                g.setColour(c.available?Colours::white:Colours::grey);g.setFont(theme::font(12));g.drawText(c.name,0,0,headerHeight-42,20,Justification::centredLeft,true);
            }
        }
        {
            Graphics::ScopedSaveState state(g);g.reduceClipRegion(16,viewport.getY(),left-16,viewport.getHeight());
            for(int row=std::max(0,yOffset/rowHeight);row<std::min((int)rows.size(),(yOffset+viewport.getHeight())/rowHeight+1);++row){
                const auto& r=rows[(size_t)row];const int y=viewport.getY()+row*rowHeight-yOffset;
                g.setColour(Colours::white.withAlpha(row==hotRow?.07f:row%2==0?.025f:0.f));g.fillRect(16,y,left-16,rowHeight);
                g.setColour(r.color);g.fillRect(16,y+6,3,rowHeight-12);g.setColour(Colours::grey);g.setFont(theme::font(12));g.drawText(r.number,28,y+6,34,20,Justification::centredLeft);
                g.setColour(Colours::white);g.setFont(r.id.empty()?theme::semiboldFont(12):theme::font(12));g.drawText(r.name,64,y+6,left-72,20,Justification::centredLeft,true);
            }
        }
        g.setColour(activeColor);g.fillEllipse(20.f,(float)getHeight()-25,7,7);g.setColour(failure.isEmpty()?Colours::grey:Colours::red);g.setFont(theme::font(12));
        g.drawText(failure.isEmpty()?localization::translate("Click a cell to connect or disconnect"):failure,36,getHeight()-38,getWidth()-56,32,Justification::centredLeft);
    }
};
} // namespace catlive
