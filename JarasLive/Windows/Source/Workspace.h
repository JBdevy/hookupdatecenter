#pragma once
#include "Auth.h"
#include "Lighting.h"
#include "Session.h"
#include "ProjectBrowser.h"
#include "Appearance.h"
#include "ActionBindings.h"
#include "StageState.h"
#include "TempoControl.h"
#include "MixerPanel.h"
#include "TrackDrop.h"
#include "PartsPanel.h"
#include "TunerControl.h"
#include "NavigationPanel.h"
#include "ResourceUsage.h"
#include "DragDivider.h"
#include "FooterKeyboard.h"
#include "ItemLayout.h"
#include "GridItemClipboard.h"
#include "EditorSelectionAreas.h"
#include "MacPopupMenuLook.h"
namespace catlive {
namespace remote { class Host; class Presentation; }
class TeleprompterHTTP;
class TransportFadeoutOverlay;
class MacLook final : public MacPopupMenuLook {
  public:
    MacLook();
    void drawButtonBackground(Graphics &, Button &, const Colour &, bool, bool) override;
    void drawButtonText(Graphics &, TextButton &, bool, bool) override;
    void drawToggleButton(Graphics &, ToggleButton &, bool, bool) override;
    void drawLinearSlider(Graphics &, int, int, int, int, float, float, float, Slider::SliderStyle,
                          Slider &) override;
    void drawScrollbar(Graphics &, ScrollBar &, int, int, int, int, bool, int, int, bool,
                       bool) override;
    Slider::SliderLayout getSliderLayout(Slider &) override;
    void drawComboBox(Graphics &, int, int, bool, int, int, int, int, ComboBox &) override;
    Font getComboBoxFont(ComboBox &) override { return theme::font(13); }
    Font getPopupMenuFont() override { return theme::font(13); }
    void fillTextEditorBackground(Graphics &, int, int, TextEditor &) override;
    void drawTextEditorOutline(Graphics &, int, int, TextEditor &) override;
    Button *createDocumentWindowButton(int) override;
    void drawDocumentWindowTitleBar(DocumentWindow &, Graphics &, int, int, int, int, const Image *,
                                    bool) override;
};
class Workspace final : public Component,
                        public FileDragAndDropTarget,
                        public DragAndDropContainer,
                        private Timer,
                        private ChangeListener {
  public:
    Workspace(Session &, Auth &, Lighting &, bool homePreview = false, File appearanceFile = {});
    ~Workspace() override;
    void paint(Graphics &) override;
    void resized() override;
    bool keyPressed(const KeyPress &) override;
    bool keyStateChanged(bool) override;
    void focusLost(FocusChangeType) override { heldShortcutKeys.clear(); }
    bool isInterestedInFileDrag(const StringArray &) override;
    void fileDragMove(const StringArray &, int, int) override;
    void fileDragExit(const StringArray &) override;
    void filesDropped(const StringArray &, int, int) override;
    void mouseDown(const MouseEvent &) override;
    void mouseWheelMove(const MouseEvent &, const MouseWheelDetails &) override;
    void requestClose(std::function<void()>);
    void capture(const File &);
    var diagnostics() const;
    void openGrandMA2();
    void openResolume();
    void openSettings();
    void openAdvanced();
    void openAudioSettings();
    void openFX(ID track = {});
    void openItemFX(ID clip);
    void chooseOpen();
    void openProject(const File &);
    void chooseSave(bool saveAs = false, std::function<void()> saved = {});
    void chooseImport();
    void chooseExport();
    void chooseSoundFont();
    void openVideo();
    void editRegion(ID);
    void showRegionMenu(ID, Point<int>);
    void exportRegions(std::set<ID>);
    void detectRegions(std::set<ID>);
    void editMultiLoops(ID);
    void deleteRegions(std::set<ID>, bool withContents = false);
    void editMarker(ID, double);
    void showMarkerMenu(ID, Point<int>);
    void editTempoMarker(ID, double);
    void runUIRegression();
    void showLoginPreview();
    void showImportNoticePreview();
    void showError(const String &);
    void showProjectBrowser();
    void projectOpened(bool fitTimeline = true);
    bool isProjectBrowserShowing() const { return browserVisible; }
    static void showPanel(const String &, std::unique_ptr<Component>, int width, int height);

  private:
    std::set<int> heldShortcutKeys;
    std::map<String, int> actionInvocations;
    class Timeline;
    std::optional<trackDrop::Destination> trackDropPreview;
    ID trackDropBlocked;
    std::optional<Point<int>> externalDropPoint;
    void paintOverChildren(Graphics &) override;
    class TrackRow;
    class TrackHeightHandle;
    std::unique_ptr<TrackHeightHandle> trackHeightHandle;
    std::optional<std::pair<ID,double>> trackHeightPreview;
    class Setlist;
    class Caption;
    Session &session;
    Auth &auth;
    Lighting &lighting;
    MacLook look;
    Appearance appearance;
    ActionBindings actions;
    EditorSelectionAreas selectionAreas;
    bool selectAllTracks();
    bool selectAllGridItems();
    void openTransportFadeout();
    void triggerTransportFadeout();
    std::unique_ptr<TransportFadeoutOverlay> fadeoutOverlay;
    bool lastFadeoutActive = false;
    StageState stage;
    std::unique_ptr<remote::Presentation> remotePresentation;
    std::unique_ptr<remote::Host> remoteHost;
    std::array<std::unique_ptr<TeleprompterHTTP>,2> teleprompterHTTP;
    void openTPRemote(int);
    std::unique_ptr<StageTimerControl> stageTimer;
    std::unique_ptr<TempoControl> tempoControl;
    std::unique_ptr<MixerPanel> footerMixer;
    std::unique_ptr<PartsPanel> partsPanel;
    std::unique_ptr<PartsPanel> partsSidebar;
    std::unique_ptr<TunerControl> tuner;
    std::unique_ptr<Caption> caption;
    std::unique_ptr<Timeline> timeline;
    std::unique_ptr<Setlist> setlist;
    std::unique_ptr<Component> loginPanel;
    std::unique_ptr<ProjectBrowser> projectBrowser;
    std::unique_ptr<NavigationPanel> navigation;
    bool browserVisible = false, projectReady = false;
    juce::Rectangle<int> editorWindowBounds;
    std::unique_ptr<FooterKeyboard> keyboard;
    Viewport tracksViewport, dockViewport;
    Component tracksContent, dockContent;
    OwnedArray<TrackRow> rows;
    OwnedArray<TextButton> buttons;
    std::map<String, std::unique_ptr<DocumentWindow>> floatingWindows;
    std::map<String, TextButton *> controls;
    GainFader masterVolume;
    ParameterSlider masterPan, zoom;
    SongDisplayLabel songDisplay;
    Label transportTime, transportInfo, footer, tempo;
    DragDivider mixerDivider, setlistDivider;
    DragDivider footerHeightDivider{false}, mixerHeightDivider{false};
    int resizeStart = 0, footerHeightSetting = 27, mixerHeightSetting = 300;
    int footerLeftWidth = 155, footerRightWidth = 230;
    juce::Rectangle<int> footerSongBounds;
    bool mixerDetached = false;
    void showDetachedMixer();
    void mixerMenu(Point<int>);
    ResourceUsage resourceUsage;
    TextButton addTrack{"+"}, timelineLock;
    std::unique_ptr<FileChooser> chooser;
    std::unique_ptr<FileLogger> logger;
    bool mixerVisible = true, setlistVisible = true, keyboardVisible = false,
         footerMixerVisible = false, partsVisible = false, partsListVisible = false;
    std::optional<bool> lastEditorVisible;
    int mixerWidth = 281, setlistWidth = 336, trackHeight = 64, verticalOffset = 0;
    double pixelsPerSecond = 20;
    ID selectedTrack, selectedClip;
    std::set<ID> selectedClips;
    bool clipSelected(const ID &id) const { return selectedClips.empty() ? selectedClip == id : selectedClips.count(id) != 0; }
    void clearItemSelection() { selectedClip.clear(); selectedClips.clear(); }
    void copyGridItems(bool moving = false);
    void pasteGridItems(bool duplicate = false);
    std::set<ID> selectedTracks;
    ID trackSelectionAnchor;
    bool trackSelected(const ID &id) const { return selectedTracks.empty() ? selectedTrack == id : selectedTracks.count(id) != 0; }
    void selectMixerTrack(const ID &, ModifierKeys, bool clearItems = true);
    void changeMixerFX(const ID &, bool remove);
    ID recordVisualSelection;
    std::optional<GridItemClipboard> itemClipboard;
    uint64 builtRevision = ~uint64(0);
    ID builtSong;
    std::vector<ID> builtTracks;
    std::set<ID> collapsedGroups;
    int shortcutCount = 0, contextCount = 0, wheelCount = 0;
    bool uiRegressionPassed = false;
    bool capturingSnapshot = false;
    double lastTick = 0;
    juce::Rectangle<int> transportBounds, workspaceBounds, footerBounds;
    TextButton &button(String, const String &, std::function<void()>, Colour colour = {});
    void rebuild();
    int rowHeight(int index) const;
    bool rowHidden(int index) const;
    void toggleGroup(const ID &);
    int rowBodyHeight(int index) const;
    const ItemLanes &itemLanes(int index) const;
    int itemLaneHeight(int index) const;
    mutable uint64 itemLayoutRevision = ~uint64(0);
    mutable std::vector<ItemLanes> itemLayouts;
    int rowTop(int index) const;
    int rowAt(int y) const;
    void updateState();
    void updateLogin();
    void timerCallback() override;
    void changeListenerCallback(ChangeBroadcaster *) override;
    void perform(std::function<void()>);
    void performAction(const String &, float, int);
    double lastTap = 0;
    bool lastSubCursorVisible = false;
    std::vector<double> tapIntervals;
    void prompt(const String &, const String &, const String &, std::function<void(String)>);
    void confirm(const String &, const String &, std::function<void()>);
    void newProject();
    void deleteRecentProject(const File &);
    void createProject(bool withStems, int recordingChannels = 0);
    void chooseRecordingProject();
    void choosePackage();
    void choosePackageDestination(const File &);
    void chooseMigration(bool logic);
    void newSong();
    void showShortcuts();
    void openRegions();
    void openPartsList();
    void showMasterMenu(Point<int>);
    void editMasterColour();
    void showTrackMenu(ID, Point<int>);
    void createTrack();
    void specialTrackAction(ID,const String &);
    void editTrack(ID);
    void showClipMenu(ID, Point<int>);
    void openMIDIEditor(ID);
    void addMIDIItem(ID, double);
    void editTextItem(ID);
    void addTextItem(ID, double);
    void showMixer();
    void showTeleprompter(int index = 1);
    void openNotices();
    void openRemote();
    void toggleRemote();
    void openStageConfig(int index = 1);
    void openAutomation(ID);
    void openTimer(bool settings = false);
    void openFloating(const String &, std::unique_ptr<Component>, int, int);
};
} // namespace catlive
