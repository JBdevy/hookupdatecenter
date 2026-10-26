#pragma once
#include "Workspace.h"
#include "UIFeatureTests.h"

namespace catlive {
// Friend access exercises the same placement operation used by the context
// menu without adding a test-only command to the application's public API.
struct WorkspaceSetlistPresentationTests {
    static void run(const File &directory) {
        const auto require=[](bool okay,const char *message) {
            if (!okay) throw std::runtime_error(message);
        };
        const auto pump=[] {
            for (int i=0;i<8;++i) {
                MSG message;
                while (PeekMessage(&message,nullptr,0,0,PM_REMOVE)) {
                    TranslateMessage(&message);DispatchMessage(&message);
                }
                Thread::sleep(2);
            }
        };
        jaras::Project project;project.id=uuid();project.name="Setlist placement";
        jaras::Song song;song.id=uuid();song.name="Two regions";song.duration=40;
        song.parts={{uuid(),"Current",0,20},{uuid(),"Queued",20,40}};
        jaras::Track track;track.id=uuid();track.name="Track";track.role.id="other";song.tracks={track};
        song.markers=std::vector<jaras::TimelineMarker>{{uuid(),"Verse",4,0x54ff93},{uuid(),"Chorus",24,0x54ff93}};
        for (auto &marker:*song.markers) marker.section=true;
        project.songs={song};project.savedCursor=jaras::SavedProjectCursor{song.id,0};
        Session session;session.inspection=true;session.audio.prepareOffline(48000);
        session.restoreSnapshot(ProjectCodec::encode(project));session.audio.setOffline(true);
        session.command(jaras::CommandKind::queueRegion,song.parts[1].id);
        const auto preferences=directory.getNonexistentChildFile("setlist-placement",".json");
        require(preferences.replaceWithText(R"({"jaras.trackColumnWidth":281,"jaras.setlistWidth":336})"),
                "Cannot create Setlist presentation preferences");
        Auth auth;Lighting lighting(session);Workspace workspace(session,auth,lighting,false,preferences);
        workspace.setSize(1366,900);
        const auto button=[&](Component &parent,const char *id) {
            auto *result=dynamic_cast<Button *>(uiFeatureTests::find(parent,id));
            require(result && bool(result->onClick),"Setlist presentation button is missing");return result;
        };
        auto *partsButton=button(workspace,"setlistParts");
        auto *list=uiFeatureTests::find(workspace,"setlistPanel");
        auto *canvas=uiFeatureTests::find(workspace,"timelineCanvas");
        auto *right=workspace.partsSidebar.get();
        require(list && canvas && right,"Setlist presentation components are missing");
        const auto before=JSON::toString(session.snapshot());
        const int savedWidth=workspace.setlistWidth;
        using Placement=Workspace::SetlistPlacement;
        const auto checkDock=[&](Placement side) {
            require(workspace.setlistPlacement==side && workspace.setlistDockSide==side &&
                    list->getParentComponent()==&workspace && right->getParentComponent()==&workspace,
                    "Docked Setlist or Parts retained the floating parent or wrong side");
            require(workspace.setlistVisible && list->isVisible() && workspace.setlistDivider.isVisible() &&
                    (!workspace.setlistWindow || !workspace.setlistWindow->isVisible()),
                    "Docking left a duplicate Setlist window or hidden list");
            const auto grid=workspace.getLocalArea(canvas,canvas->getLocalBounds());
            require(grid.getWidth()>0 && workspace.getLocalBounds().contains(grid) &&
                    workspace.getLocalBounds().contains(list->getBounds()) && !list->getBounds().intersects(grid),
                    "Docked Setlist overlaps or clips the timeline");
            if (side==Placement::left) {
                require(list->getX()==32 && list->getRight()==workspace.setlistDivider.getX() &&
                        workspace.setlistDivider.getWidth()==14 &&
                        workspace.setlistDivider.getRight()==workspace.tracksViewport.getX() &&
                        workspace.tracksViewport.getRight()==workspace.mixerDivider.getX() &&
                        workspace.mixerDivider.getWidth()==20 && workspace.mixerDivider.getRight()==grid.getX() &&
                        !workspace.partsLeftVisible,
                        "Left Setlist is not before the track mixer or did not close left Parts");
            } else {
                require(workspace.tracksViewport.getX()==32 && grid.getRight()==workspace.setlistDivider.getX() &&
                        workspace.setlistDivider.getWidth()==14 && list->getX()==workspace.setlistDivider.getRight(),
                        "Right Setlist changed the mixer origin or lost its reserved 14 px divider margin");
            }
            if (workspace.partsRightVisible)
                require(right->isVisible() && right->getRight()==workspace.getWidth() &&
                        right->getX()>=grid.getRight() && !right->getBounds().intersects(list->getBounds()),
                        "Right Parts moved to the left or overlapped a docked Setlist");
        };
        checkDock(Placement::right);
        button(workspace,"railParts")->onClick();
        require(workspace.partsLeftVisible && workspace.tracksViewport.isVisible() &&
                workspace.partsLeft->getRight()==workspace.tracksViewport.getX(),
                "Left Parts must coexist before the track mixer");
        const int mixerWidth=workspace.mixerWidth;
        const int leftPartsWidth=workspace.partsLeft->getWidth();
        workspace.showMixer();
        require(workspace.partsLeftVisible && !workspace.tracksViewport.isVisible() &&
                workspace.partsLeft->getWidth()==leftPartsWidth && workspace.mixerWidth==mixerWidth,
                "showMixer closed or resized Parts instead of hiding only the track mixer");
        workspace.showMixer();
        require(workspace.partsLeftVisible && workspace.tracksViewport.isVisible() &&
                workspace.partsLeft->getRight()==workspace.tracksViewport.getX() && workspace.mixerWidth==mixerWidth,
                "showMixer did not restore the track mixer beside Parts");
        partsButton->onClick();button(*right,"partsQueuedTab")->onClick();
        workspace.setSetlistPlacement(Placement::left);checkDock(Placement::left);
        require(workspace.tracksViewport.isVisible() && (bool)get(right->diagnostics(),"secondaryTab"),
                "Moving Setlist left must close only left Parts and preserve the track mixer and right Parts tab");
        // Reparenting must keep the same list, Parts bank, selected tab and data.
        for (const auto side:{Placement::left,Placement::right}) {
            workspace.setSetlistPlacement(side);checkDock(side);
            workspace.setSetlistPlacement(Placement::detached);
            auto *window=workspace.setlistWindow.get();
            require(window && window->isVisible() && window->getContentComponent(),
                    "Detaching Setlist did not create a visible native window");
            auto *panel=window->getContentComponent();
            require(list->getParentComponent()==panel && right->getParentComponent()==panel &&
                    uiFeatureTests::find(*window,"setlistParts")==partsButton &&
                    !uiFeatureTests::find(workspace,"setlistParts") && !workspace.setlistDivider.isVisible(),
                    "Detached Setlist duplicated its list, lost Parts or left its old divider");
            require(right->isVisible() && list->getRight()==right->getX() &&
                    panel->getLocalBounds().contains(list->getBounds()) && panel->getLocalBounds().contains(right->getBounds()) &&
                    window->getWidth()>=620 && (bool)get(right->diagnostics(),"secondaryTab"),
                    "Detached Parts is clipped, lost its bank or overlaps the Setlist");
            require(workspace.tracksViewport.getX()==32 && workspace.setlistWidth==savedWidth &&
                    workspace.setlistDockSide==side,
                    "Detaching changed the remembered dock width, origin or side");
            workspace.setSetlistPlacement(Placement::detached);
            require(workspace.setlistWindow.get()==window && list->getParentComponent()==panel,
                    "Repeated detach created a second Setlist window or list");
            button(workspace,"setlist")->onClick();
            require(!window->isVisible() && workspace.setlistPlacement==Placement::detached,
                    "Transport Setlist did not hide the floating window without docking");
            button(workspace,"setlist")->onClick();
            require(window->isVisible() && list->getParentComponent()==panel,
                    "Transport Setlist did not restore the existing floating window");
            partsButton->onClick();
            require(!right->isVisible() && list->getWidth()==panel->getWidth(),
                    "Closing detached Parts retained an empty sidebar");
            partsButton->onClick();
            require(right->isVisible() && (bool)get(right->diagnostics(),"secondaryTab"),
                    "Reopening detached Parts lost its selected tab");
            workspace.browserVisible=true;workspace.resized();
            require(!window->isVisible(),"Detached Setlist stayed above the project browser");
            workspace.browserVisible=false;workspace.resized();
            require(window->isVisible(),"Returning to the editor did not restore detached Setlist");
            workspace.loginPanel=std::make_unique<Component>();workspace.resized();
            require(!window->isVisible(),"Detached Setlist stayed above the login screen");
            workspace.loginPanel.reset();workspace.resized();
            require(window->isVisible(),"Leaving login did not restore detached Setlist");
            window->closeButtonPressed();pump();checkDock(side);
            require(uiFeatureTests::find(workspace,"setlistParts")==partsButton &&
                    workspace.partsSidebar.get()==right && workspace.setlistWidth==savedWidth &&
                    (bool)get(right->diagnostics(),"secondaryTab"),
                    "Closing Setlist did not restore the same controls, dock width and Parts tab");
        }
        require(JSON::toString(session.snapshot())==before,
                "Setlist presentation modified the project, selected region or cursor");
    }
};
template <typename Register>
void addWorkspaceSetlistPresentationTests(const File &directory,Register &&test) {
    test("Setlist docks on either side and detaches once with Parts, preserved state and browser/login isolation",[&] {
        WorkspaceSetlistPresentationTests::run(directory);
    });
}
} // namespace catlive
