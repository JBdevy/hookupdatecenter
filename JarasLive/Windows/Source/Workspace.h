#pragma once
#include "Auth.h"
#include "Lighting.h"
#include "Session.h"
#include "ProjectBrowser.h"
#include "SetlistRows.h"
#include "Appearance.h"
#include "ActionBindings.h"
#include "SMK37Connection.h"
#include "StageState.h"
#include "TempoControl.h"
#include "MixerPanel.h"
#include "TrackDrop.h"
#include "PartsPanel.h"
#include "TunerControl.h"
#include "ResourceUsage.h"
#include "DragDivider.h"
#include "FooterKeyboard.h"
#include "VinhetasPanel.h"
#include "ItemLayout.h"
#include "GridItemClipboard.h"
#include "EditorSelectionAreas.h"
#include "MacPopupMenuLook.h"
#include "ExternalMediaDrop.h"
#include "RemoteProjectCatalog.h"
#include "TrackVisibility.h"
#include "TrackMixerViewport.h"
#include "TrackRowGeometry.h"
#include "TimelineSnapping.h"
namespace catlive {
class AudioPreparationOverlay;
class WorkspaceLibrary;
namespace native { class TransportButtons; }
namespace remote { class Host; class Presentation; }
class TeleprompterHTTP;
class TransportFadeoutOverlay;
class MacLook final : public MacPopupMenuLook {
  public:
    MacLook();
    void refreshThemeColours();
    void drawProgressBar(Graphics &, ProgressBar &, int, int, double, const String &) override;
    juce::Rectangle<int> getTooltipBounds(const String &, juce::Point<int>, juce::Rectangle<int>) override;
    void drawTooltip(Graphics &,const String &,int,int) override;
    void drawButtonBackground(Graphics &, Button &, const Colour &, bool, bool) override;
    void drawButtonText(Graphics &, TextButton &, bool, bool) override;
    void drawToggleButton(Graphics &, ToggleButton &, bool, bool) override;
    void drawLinearSlider(Graphics &, int, int, int, int, float, float, float, Slider::SliderStyle,
                          Slider &) override;
    void drawRotarySlider(Graphics &, int, int, int, int, float, float, float, Slider &) override;
    void drawScrollbar(Graphics &, ScrollBar &, int, int, int, int, bool, int, int, bool,
                       bool) override;
    Slider::SliderLayout getSliderLayout(Slider &) override;
    void drawComboBox(Graphics &, int, int, bool, int, int, int, int, ComboBox &) override;
    Font getComboBoxFont(ComboBox &box) override { return box.getComponentID()=="setlistPlaylistSelector" ? theme::semiboldFont(9) : theme::font(13); }
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
    Workspace(Session &, Auth &, Lighting &, bool homePreview = false, File appearanceFile = {}, std::shared_ptr<remote::Host> host = {});
    ~Workspace() override;
    void paint(Graphics &) override;
    std::pair<Colour, Colour> transportPanelColours() const;
    void resized() override;
    bool keyPressed(const KeyPress &) override;
    bool keyStateChanged(bool) override;
    void focusLost(FocusChangeType) override { heldShortcutKeys.clear(); }
    bool isInterestedInFileDrag(const StringArray &) override;
    void fileDragEnter(const StringArray &, int, int) override;
    void fileDragMove(const StringArray &, int, int) override;
    void fileDragExit(const StringArray &) override;
    void filesDropped(const StringArray &, int, int) override;
    void mouseDown(const MouseEvent &) override;
    void mouseDoubleClick(const MouseEvent &) override;
    void mouseWheelMove(const MouseEvent &, const MouseWheelDetails &) override;
    void requestClose(std::function<void()>, bool application = true,
                      std::optional<bool> saveAll = {}, std::function<void()> cancelled = {});
    Component &windowCaption();
    bool isProjectOpen() const { return projectReady; }
    void returnToWorkspace();
    void resetProjectTab();
    void capture(const File &);
    var diagnostics() const;
    void openGrandMA2();
    void openResolume();
    void openSettings();
    void openAdvanced();
    void openAudioSettings();
    void openFX(ID track = {}, String preferredEffect = {});
    void openItemFX(ID clip);
    std::shared_ptr<remote::Host> projectRemoteHost() const { return remoteHost; }
    void activateProjectTab();
    void deactivateProjectTab();
    std::function<bool(File)> activateExistingProjectTab;
    std::function<void(String)> projectTabLoadFinished;
    std::function<void(File)> openInNewProjectTab;
    std::function<void(std::vector<File>)> openMultipleProjectTabs;
    std::function<std::vector<std::pair<ID,Session *>>()> multitrackTabs;
    std::function<void(File, ID)> openRemoteProjectInNewTab;
    std::function<void(int)> navigateProjectTab;
    std::function<void()> toggleWorkspaceFullscreen;
    bool workspaceFullscreen = false;
    const jaras::ID remoteProjectTabID = uuid();
    std::function<var()> remoteProjectTabs;
    std::function<void(const String &)> selectRemoteProjectTab;
    std::function<void(const String &)> closeRemoteProjectTab;
    std::function<bool(int)> canNavigateProjectTab;
    void chooseOpen(bool projectOnly = false);
    void openProject(const File &, std::function<void()> loaded = {}, bool confirmed = false, bool allowMissing = false, ID remoteRequest = {}, bool fromFileRecents = false);
    void chooseSave(bool saveAs = false, std::function<void()> saved = {}, std::function<void()> cancelled = {},
                    bool separateFolder = false);
    void chooseImport(bool adding = true, bool inNewTab = false);
    void chooseExport();
    void chooseSoundFont();
    void openVideo();
    void editRegion(ID);
    void showRegionMenu(ID, Point<int>, std::set<ID> selection);
    void exportRegions(std::set<ID>);
    void exportMultitrack(std::set<ID>);
    void detectRegions(std::set<ID>);
    void showRulerRangeMenu(std::pair<double,double>, Point<int>);
    void editMultiLoops(ID);
    void deleteRegions(std::set<ID>, bool withContents = false);
    void editMarker(ID, double, bool section = false);
    void showMarkerMenu(ID, Point<int>);
    void editTempoMarker(ID, double);
    void runUIRegression();
    void runMediaImportRegression(const File &, std::function<void(bool)>);
    void showLoginPreview();
    void showImportNoticePreview();
    void showError(const String &, const String &title = "CatLive");
    void showProjectBrowser();
    void confirmProjectReplacement(const String &, std::function<void()>, std::function<void()> cancelled = {}, bool confirmedRemotely = false);
    std::function<void(String)> beginProjectLoading(const File &, const String &);
    void projectOpened(bool fitTimeline = true);
    bool isLoginShowing() const { return loginPanel != nullptr; }
    bool isProjectBrowserShowing() const { return browserVisible; }
    static void showPanel(const String &, std::unique_ptr<Component>, int width, int height);

  private:
    std::set<int> heldShortcutKeys;
    int elasticDeleteKey = 0;
    std::unique_ptr<meterDisplay::PeakReadout> masterPeakReadout;
    int masterMuteBlinkPhase = -1;
    bool timelineEditMode = false;
    jaras::CommandKind timelineEditSeek = jaras::CommandKind::queueBarSeek;
    bool lastSetlistPlaying = false;
    std::unique_ptr<native::TransportButtons> nativeTransport;
    void syncNativeTransport();
    void layoutTransportSongTitle();
    enum class TransportTitleMode { none, region, markers, nextMarker, nextTimelineRegion, nextSetlistRegion, queue };
    TransportTitleMode transportTitleMode = TransportTitleMode::region;
    inline static constexpr std::array<const char *, 7> transportTitleOptions{
        "None", "Region", "Markers", "Next Marker", "Next Region Timeline", "Next Region Setlist", "Fila de espera"};
    void showTransportTitleMenu(Point<int>);
    void refreshAlternateTransportTitle(const jaras::TransportState &);
    void refreshPlaybackState();
    std::unique_ptr<AudioPreparationOverlay> audioPreparationOverlay;
    std::optional<double> audioPreparationStarted;
    std::optional<std::string> masterFXColourSource;
    Colour masterFXColour=Colours::white;
    std::map<String, int> actionInvocations;
    class Timeline;
    std::optional<trackDrop::Destination> trackDropPreview;
    ID trackDropBlocked, scrollingTrackDrag;
    std::optional<Point<int>> externalDropPoint;
    std::vector<externalMedia::Preview> externalDropFiles;
    std::shared_ptr<std::atomic<bool>> externalDropCancelled;
    void clearExternalDrop();
    void addStandardTrackAtEnd();
    int fileDragEntries = 0, fileDropCount = 0;
    String fileDropStatus;
    void paintOverChildren(Graphics &) override;
    class TrackRow;
    class TrackHeightHandle;
    std::unique_ptr<TrackHeightHandle> trackHeightHandle;
    std::optional<std::pair<ID,double>> trackHeightPreview;
    class Setlist;
    friend struct WorkspaceSetlistPresentationTests;
    friend struct PartsDividerTests;
    friend struct TrackVisibilityTests;
    friend struct MasterMixerTests;
    friend struct HozMixerFocusTests;
    friend struct WorkspaceLayoutTests;
    class Caption;
    Session &session;
    Auth &auth;
    Lighting &lighting;
    MacLook look;
    std::unique_ptr<juce::TooltipWindow> toolbarTooltips;
    Appearance appearance;
    TrackVisibility trackVisibility;
    void openTrackVisibility();
    void setTrackVisibility(TrackVisibility::Panel,const ID &,bool);
    void pruneTrackVisibilitySelection(bool footer);
    void refreshTrackVisibility();
    std::unique_ptr<SMK37Connection> smk37;
    void performSMK37(int);
    void updateSMK37();
    ActionBindings actions;
    EditorSelectionAreas selectionAreas;
    bool selectAllTracks(bool footer = false);
    bool selectAllGridItems();
    void openTransportFadeout();
    void triggerTransportFadeout();
    std::unique_ptr<TransportFadeoutOverlay> fadeoutOverlay;
    bool lastFadeoutActive = false, lastLoopMixerActive = false;
    StageState stage;
    std::unique_ptr<remote::Presentation> remotePresentation;
    std::shared_ptr<remote::Host> remoteHost;
    remote::ProjectCatalog remoteProjectCatalog;
    StringArray remoteRecentPaths;
    double remoteRecentReadAt = 0;
    String remoteProjectError;
    std::array<std::unique_ptr<TeleprompterHTTP>,2> teleprompterHTTP;
    void openTPRemote(int);
    String toolbarAudioFormat;
    std::unique_ptr<StageTimerReadout> stageTimer;
    std::unique_ptr<TempoControl> tempoControl;
    std::unique_ptr<MixerPanel> footerMixer, focusMixer;
    std::unique_ptr<WorkspaceLibrary> workspaceLibrary, proLibraryDock;
    enum class ProDock { none, notes, samplers };
    ProDock proDock = ProDock::none;
    bool proTransport = true;
    enum class ProTool { select, cut, mute, solo, exclusiveSolo };
    static bool isTrackCursorTool(ProTool tool) { return tool == ProTool::mute || tool == ProTool::solo || tool == ProTool::exclusiveSolo; }
    void applyTrackCursorTool(ProTool, const ID &);
    ProTool proTool = ProTool::select;
    juce::Rectangle<int> proPlaybackBounds, proTimeBounds;
    juce::Rectangle<int> transportResourceBounds;
    ID proTimingSong;
    uint64_t proTimingRevision = 0;
    std::vector<timelineGrid::Section> proTimingSections;
    std::optional<timelineGrid::MeasureLabels> proMeasureLabels;
    std::array<int64_t,7> proPosition{};
    bool proPositionRunning = false;
    SafePointer<Label> clockPositionLabel;
    void updateProPosition(double);
    void toggleProDock(ProDock);
    DragDivider libraryDivider, proLibraryDivider;
    int libraryWidth = 344, libraryResizeStart = 344;
    static constexpr int minProLibraryWidth = 200, maxProLibraryWidth = 559;
    int proLibraryWidth = 0, proLibraryResizeStart = 0;
    int proLibraryWidthLimit() const;
    struct DockHeights { int mixer = 0, parts = 0, total = 0, visible = 0, preview = 0; } dockHeights;
    void layoutWorkspaceColumns(bool widthOnly, bool togglingPanel = false);
    void layoutTrackRows();
    void refreshTrackHeightGeometry(std::optional<int> visibleY = std::nullopt);
    bool adjustingTrackRowGeometry = false;
    bool libraryVisible = false;
    std::unique_ptr<PartsPanel> partsLeft;
    std::unique_ptr<PartsPanel> partsSidebar;
    std::unique_ptr<TunerControl> tuner;
    std::unique_ptr<Caption> caption;
    std::unique_ptr<Timeline> timeline;
    std::unique_ptr<Setlist> setlist;
    std::unique_ptr<Component> loginPanel;
    std::unique_ptr<ProjectBrowser> projectBrowser;
    bool browserVisible = false, projectReady = false;
    juce::Rectangle<int> editorWindowBounds;
    std::unique_ptr<FooterKeyboard> keyboard;
    std::unique_ptr<VinhetasPanel> vinhetasPanel;
    bool vinhetasVisible = false, vinhetasDetached = false;
    enum class PerformancePanel { parts, mixer, pads, midiPreview, keyboard };
    void activatePerformancePanel(PerformancePanel);
    void closePads();
    void toggleVinhetasDock();
    void toggleMIDIPreviewDock();
    std::unique_ptr<Component> midiPreviewPanel;
    bool midiPreviewVisible = false, midiPreviewDetached = false;
    DragDivider midiPreviewDivider{false};
    int midiPreviewHeight = 273;
    TrackMixerViewport tracksViewport;
    struct DockViewport final : Viewport {
        std::function<void(int)> scrolled;
        void visibleAreaChanged(const juce::Rectangle<int> &area) override {
            if (scrolled) scrolled(area.getY());
        }
    } dockViewport;
    Component tracksContent, dockContent;
    OwnedArray<TrackRow> rows;
    OwnedArray<TextButton> buttons;
    std::map<String, std::unique_ptr<DocumentWindow>> floatingWindows;
    std::optional<unsigned> auxiliaryWindowSuppression;
    std::map<String, TextButton *> controls;
    GainFader masterVolume;
    ParameterSlider masterPan, zoom, trackHeightSlider;
    std::optional<std::pair<double, double>> transportProgressRange;
    int transportProgressPixels = -1;
    juce::Rectangle<float> transportProgressBounds() const {
        constexpr float progressHeight = 3.2f;
        auto lane = transportDisplayBounds.reduced(3, 0).toFloat().withHeight(progressHeight);
        return lane.withY(float(transportBounds.getBottom() - 1) - progressHeight);
    }
    std::unique_ptr<Component> saveIndicator;
    void refreshSaveIndicator();
    Label songDisplay, transportTime, transportInfo, footer, tempo;
    DragDivider mixerDivider, setlistDivider, partsLeftDivider, partsRightDivider;
    DragDivider footerHeightDivider{false}, mixerHeightDivider{false};
    int resizeStart = 0, footerHeightSetting = 27, mixerHeightSetting = 300, mixerHeightLimit = 724, midiPreviewHeightLimit = 724;
    juce::Rectangle<int> footerSongBounds, footerNoticeBounds;
    bool mixerDetached = false;
    bool layoutInitialized = false, layoutActive = true, restoringLayout = false;
    double layoutSaveTime = 0;
    String lastSavedLayout;
    void saveWorkspaceLayout();
    void restoreWorkspaceLayout();
    enum class SetlistPlacement { right, left, detached };
    SetlistPlacement setlistPlacement = SetlistPlacement::right;
    SetlistPlacement setlistDockSide = SetlistPlacement::right;
    class DetachedSetlistPanel;
    std::unique_ptr<DocumentWindow> setlistWindow;
    void setSetlistPlacement(SetlistPlacement);
    void setlistMenu(Point<int>);
    void layoutDetachedSetlist();
    void resizePartsWidth(bool left, int delta);
    void showDetachedMixer();
    void updateHozMixerView(HozMixerView options);
    std::map<ID, std::uint32_t> readHozMixerTrackOverrides() const;
    void refreshToolbarPanelIndicators();
    void refreshInterfaceTheme();
    void mixerMenu(Point<int>);
    ResourceUsage resourceUsage;
    bool transportMIDIActive = false;
    TextButton addTrack{"+"}, trackVisibilityButton, timelineSnap, timelineTimebase;
    QuietButton trackComponentsPreset;
    QuietButton trackVUButton;
    QuietButton timelineLock;
    bool freeTimelinePosition(ModifierKeys mods) const { return !(bool)appearance.value("jaras.timeline.snapEnabled", true) || mods.isShiftDown(); }
    std::unique_ptr<FileChooser> chooser;
    std::unique_ptr<FileLogger> logger;
    bool mixerVisible = true, setlistVisible = true, keyboardVisible = false,
         footerMixerVisible = false, focusVisible = false, partsLeftVisible = false, partsRightVisible = false, partsLeftHorizontal = false;
    bool laidOutFocusWithSelection = false;
    std::optional<bool> lastEditorVisible;
    int mixerWidth = theme::trackMixerMinWidth, setlistWidth = 336, trackHeight = theme::trackMixerMinHeight, verticalOffset = 0;
    int horizontalPartsHeight = PartsPanel::defaultHorizontalHeight;
    int partsLeftWidth = 260, partsRightWidth = 0; // Zero keeps the original automatic right width until resized.
    double pixelsPerSecond = 20;
    std::optional<int> trackHeightMemory;
    std::optional<double> zoomMemory;
    ID selectedTrack, selectedClip;
    std::set<ID> selectedClips;
    bool clipSelected(const ID &id) const { return selectedClips.empty() ? selectedClip == id : selectedClips.count(id) != 0; }
    void clearItemSelection() { selectedClip.clear(); selectedClips.clear(); session.selectProgramChange({}); }
    void selectProgramMarker(const ID&);
    void pasteProgramMarker();
    void copyGridItems(bool moving = false);
    void pasteGridItems(bool duplicate = false);
    std::vector<int> gridMediaDropRows(int row, size_t limit) const;
    void importMediaAt(const Array<File> &, double at, ID target, std::vector<ID> gridTracks = {});
    std::set<ID> selectedTracks;
    ID trackSelectionAnchor;
    bool trackSelected(const ID &id) const { return selectedTracks.empty() ? selectedTrack == id : selectedTracks.count(id) != 0; }
    void selectMixerTrack(const ID &, ModifierKeys, bool clearItems = true, bool footer = false);
    bool stepMixerTrack(int direction, bool rename = false);
    bool trackSelectionFromFooter = false;
    void changeMixerFX(const ID &, bool remove);
    void mapMixerControl(const ID &, jaras::CommandKind);
    ID recordVisualSelection;
    std::optional<GridItemClipboard> itemClipboard;
    std::optional<DWORD> itemClipboardSequence;
    struct CopiedTracks { var document; ID song; std::set<ID> targets; DWORD sequence; std::map<ID, ID> previousCopies; ID lastSelected; };
    std::optional<CopiedTracks> trackClipboard;
    uint64 builtRevision = ~uint64(0);
    ID builtSong;
    std::vector<ID> builtTracks;
    std::set<ID> collapsedGroups;
    int shortcutCount = 0, contextCount = 0, wheelCount = 0;
    bool uiRegressionPassed = false;
    bool capturingSnapshot = false;
    double lastTick = 0;
    juce::Rectangle<int> transportBounds, transportDisplayBounds, timelineEditingBounds, tempoDisplayBounds, workspaceBounds, footerBounds;
    TextButton &button(String, const String &, std::function<void()>, Colour colour = {});
    void rebuild();
    void selectAndRevealTrackCopies(const std::vector<ID> &copies);
    int rowHeight(int index) const;
    bool rowHidden(int index) const;
    void toggleGroup(const ID &);
    int rowBodyHeight(int index) const;
    int measureRowBodyHeight(int index) const;
    void prepareRowGeometry() const;
    void invalidateRowGeometry() { rowGeometryRevision = ~uint64(0); }
    mutable TrackRowGeometry rowGeometry;
    mutable uint64 rowGeometryRevision = ~uint64(0);
    mutable ID rowGeometrySong;
    ItemLanes makeItemLanes(const jaras::Track& track) const;
    const ItemLanes &itemLanes(int index) const;
    int minimumTrackHeight() const;
    int itemLaneHeight(int index) const;
    ItemLanes::Geometry itemGeometry(int index, const ID &clip, const ItemLanes *preview = nullptr) const;
    mutable uint64 itemLayoutRevision = ~uint64(0);
    mutable std::vector<ItemLanes> itemLayouts;
    String itemTitle(const jaras::AudioClip &) const;
    mutable uint64 itemTitleRevision = ~uint64(0);
    mutable ID itemTitleSong;
    mutable std::map<ID,String> itemTitles;
    mutable std::unique_ptr<jaras::TempoEditMap::PlaybackRates> itemTitleTempo;
    int rowTop(int index) const;
    int rowAt(int y) const;
    void updateState();
    void updateLogin();
    void timerCallback() override;
    void changeListenerCallback(ChangeBroadcaster *) override;
    void perform(std::function<void()>);
    void performAction(const String &, float, int);
    bool lastSubCursorVisible = false;
    void prompt(const String &, const String &, const String &, std::function<void(String)>);
    void confirm(const String &, const String &, std::function<void()>, std::function<void()> cancelled = {}, String action = {}, bool destructive = false, bool vertical = false);
    void confirmTrackDeletion(const std::set<ID> &, std::function<void()>);
    void newProject();
    void deleteRecentProject(const File &);
    void createTemporaryProject();
    void createProject(bool withStems, int recordingChannels = 0, bool inNewTab = false);
    void chooseRecordingProject();
    void choosePackage();
    void choosePackageDestination(const File &);
    void chooseMigration(bool logic);
    void newSong();
    void showShortcuts();
    void toggleFocus();
    void toggleLeftParts();
    void leftPartsMenu(Point<int>);
    void detachLeftParts();
    bool partsLeftDetached = false;
    void toggleRightParts();
    PopupMenu masterMenu(bool barMixer) const;
    void showMasterMenu(Point<int>, bool barMixer = false);
    void showFileMenu();
    void shareProject();
    void chooseTimelineFile(int type);
    void handleMasterMenu(int choice, bool barMixer);
    void setBarMixerMasterRight(bool);
    void syncBarMixerMasterSide();
    void syncHozMixerTrackStyle();
    void showTrackMenu(ID, Point<int>, bool trackMixerMenu = true, bool hozMixerMenu = false);
    void toggleTrackMixerComponents(const std::set<ID>&, int mask);
    int activeTrackComponentsPresetMask() const;
    void showTrackComponentsPresetMenu(Point<int>);
    void showChordMenu(const ID& track, const ID& marker, Point<int>);
    void createTrack();
    void specialTrackAction(ID,const String &);
    void editTrack(ID, std::set<ID> targets = {});
    void editTrackIcon(ID);
    void showClipMenu(ID, Point<int>);
    std::function<void(int)> clipMenuAction(ID, ID ownerID = {});
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
    void openFloating(const String &, std::unique_ptr<Component>, int, int, const String &key = {});
    void openSettingsPage(int);
};
} // namespace catlive
