#pragma once
#include "Common.h"

namespace catlive {
    // A viewport with per-entry heights: blocks occupy 28px, songs 38px.
    class SetlistRows final : public Component {
        struct Row final : Component {
            SetlistRows &list; int index; std::unique_ptr<Component> drawer;
            bool deferredClick=false, dragged=false;
            Row(SetlistRows &l,int i):list(l),index(i) {}
            void paint(Graphics &g) override { if(list.model) list.model->paintListBoxItem(index,g,getWidth(),getHeight(),list.selected.contains(index)); }
            void resized() override { if(drawer)drawer->setBounds(getLocalBounds()); }
            void mouseDown(const MouseEvent &e) override {
                deferredClick=false;dragged=false;
                if(!list.model)return;
                deferredClick=!e.mods.isPopupMenu() && !e.mods.isShiftDown() &&
                    !e.mods.isCommandDown() && !e.mods.isCtrlDown() &&
                    list.selected.contains(index) && list.selected.size()>1;
                if(!e.mods.isPopupMenu()) {
                    if(e.mods.isShiftDown()&&list.anchor>=0)list.selectRangeOfRows(std::min(list.anchor,index),std::max(list.anchor,index));
                    else if(e.mods.isCommandDown()||e.mods.isCtrlDown()) {
                        if(list.selected.contains(index))list.selected.removeRange({index,index+1});
                        else list.selected.addRange({index,index+1});
                        list.changed(index);
                    } else if(!list.selected.contains(index))list.selectRow(index,false,true);
                    list.anchor=index;
                }
                if(!deferredClick)list.model->listBoxItemClicked(index,e);
            }
            void mouseUp(const MouseEvent &e) override {
                const bool click=deferredClick && !dragged && !e.mouseWasDraggedSinceMouseDown() && getLocalBounds().contains(e.getPosition());
                deferredClick=false;
                if(click && list.model) {
                    list.selectRow(index,false,true);
                    list.model->listBoxItemClicked(index,e);
                }
            }
            void mouseDoubleClick(const MouseEvent &e) override { if(list.model&&!e.mods.isPopupMenu())list.model->listBoxItemDoubleClicked(index,e); }
            void mouseDrag(const MouseEvent &e) override {
                if(!list.model||!e.mouseWasDraggedSinceMouseDown()||e.mods.isPopupMenu())return;
                dragged=true;
                if(auto *container=DragAndDropContainer::findParentDragContainerFor(this);container&&!container->isDragAndDropActive()) {
                    auto description=list.model->getDragSourceDescription(list.selected);
                    if(!description.isVoid()) {
                        const auto *display=Desktop::getInstance().getDisplays().getDisplayForRect(getScreenBounds());
                        const double scale=Component::getApproximateScaleFactorForComponent(&list)*(display?display->scale:1.0);
                        const Point<int> offset{-jlimit(80,300,getWidth())/2,-17};
                        container->startDragging(description,&list,list.createDragPreview(scale,index),false,&offset,&e.source);
                    }
                }
            }
        };
        Viewport viewport; Component content; ListBoxModel *model=nullptr;
        std::vector<std::unique_ptr<Row>> rows; SparseSet<int> selected; int anchor=-1;
        void changed(int row) { content.repaint();if(model)model->selectedRowsChanged(row); }
      public:
        std::function<int(int)> heightForRow;
        std::function<String(int)> dragNameForRow;
        SetlistRows() { addAndMakeVisible(viewport);viewport.setViewedComponent(&content,false); }
        ~SetlistRows() override {viewport.setViewedComponent(nullptr,false);}
        void setModel(ListBoxModel *value){model=value;}
        ListBoxModel *getModel() const { return model; }
        int getRowHeight(int row) const { return heightForRow ? heightForRow(row) : 38; }
        void setRowHeight(int){}
        void setMultipleSelectionEnabled(bool){}
        void setOutlineThickness(int){}
        Viewport *getViewport(){return &viewport;}
        const Viewport *getViewport() const{return &viewport;}
        SparseSet<int> getSelectedRows() const{return selected;}
        ScaledImage createDragPreview(double scale=1.0, int sourceRow=-1) {
            if(!model)return {};
            auto draggable=[&](int index) {
                if(index<0 || index>=(int)rows.size() || !selected.contains(index))return false;
                SparseSet<int> single;single.addRange({index,index+1});
                return !model->getDragSourceDescription(single).isVoid();
            };
            if(!draggable(sourceRow)) {
                sourceRow=-1;
                for(int i=0;i<selected.size();++i)
                    if(draggable(selected[i])) {sourceRow=selected[i];break;}
            }
            if(sourceRow<0)return {};
            // Match the Mac's single title strip, even for a multi-selection.
            // Keeping the preview separate from the row painting leaves the
            // destination and insertion line visible beneath the pointer.
            constexpr int height=34;
            const int width=jlimit(80,300,rows[(size_t)sourceRow]->getWidth());
            scale=std::max(1.0,scale);
            Image preview(Image::ARGB,(int)std::ceil(width*scale),(int)std::ceil(height*scale),true);
            Graphics g(preview);g.addTransform(AffineTransform::scale((float)scale));
            g.setColour(Colour(0xff111111).withAlpha(.9f));
            g.fillRoundedRectangle(0,0,(float)width,(float)height,4);
            g.setColour(Colours::white);g.setFont(theme::semiboldFont(12));
            g.drawText(dragNameForRow ? dragNameForRow(sourceRow) : String{},
                       8,0,width-16,height,Justification::centredLeft,true);
            return ScaledImage(preview,scale);
        }
        int rowTop(int index) const {int y=0;for(int i=0;i<index&&i<(int)rows.size();++i)y+=heightForRow?heightForRow(i):38;return y;}
        int insertionRow(int y) const {for(int i=0;i<(int)rows.size();++i)if(y<rowTop(i)+(heightForRow?heightForRow(i):38)/2)return i;return (int)rows.size();}
        void updateContent() {
            const int count=model?model->getNumRows():0;
            while((int)rows.size()>count)rows.pop_back();
            while((int)rows.size()<count){auto row=std::make_unique<Row>(*this,(int)rows.size());content.addAndMakeVisible(*row);rows.push_back(std::move(row));}
            for(auto &row:rows) {
                auto *previous=row->drawer.release();
                row->drawer.reset(model->refreshComponentForRow(row->index,selected.contains(row->index),previous));
                if(row->drawer)row->addAndMakeVisible(*row->drawer);
            }
            resized();content.repaint();
        }
        void deselectAllRows(){selected.clear();changed(-1);}
        void selectRangeOfRows(int first,int last){selected.clear();selected.addRange({first,last+1});changed(last);}
        void selectRow(int row,bool scroll=true,bool deselectOthers=true){if(deselectOthers)selected.clear();selected.addRange({row,row+1});changed(row);if(scroll)scrollToEnsureRowIsOnscreen(row);}
        void scrollToEnsureRowIsOnscreen(int row){int top=rowTop(row),bottom=rowTop(row+1),y=viewport.getViewPositionY();if(top<y)viewport.setViewPosition(0,top);else if(bottom>y+viewport.getHeight())viewport.setViewPosition(0,bottom-viewport.getHeight());}
        void paint(Graphics &g) override {g.fillAll(theme::background);}
        void resized() override {
            viewport.setBounds(getLocalBounds());const int width=viewport.getMaximumVisibleWidth();int y=0;
            for(auto &row:rows){int h=heightForRow?heightForRow(row->index):38;row->setBounds(0,y,width,h);y+=h;}
            content.setSize(width,y);
        }
    };

} // namespace catlive
