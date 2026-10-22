CatLive Windows — Windows 10 / 11, x64

Execute CatLive.exe. No .NET, browser, Electron or WebView runtime is required.
Audio and account services are opened only during a normal launch.
The visual inspection mode does not authorise audio or create a trial.

Projects
Open .jl projects using Ctrl+O or drag a .jl file into the app.
Keep Stems beside the .jl file. Each project uses its own directory.
Ctrl+S saves an AES-256-GCM document using the same envelope as the Mac app.
Ctrl+Shift+S copies the project and referenced audio to another directory.
Unrecognised JSON fields are retained on Windows saves.
The updated Mac build also preserves windowsLighting (grandMA2 map and settings).
Older distributed Mac builds need updating before saving Windows lighting projects.

Default editing shortcuts follow Mac: S splits items, Shift+S solos the selected
track, M mutes it, R toggles repetition, Shift+Space controls Sub Play, N opens
normalization, +/- changes BPM, and Q/[ goes to project start/end. Ctrl replaces
Command for project/editing shortcuts. Ctrl+wheel zooms; F fits the full timeline.
Assignments are editable under Settings > Actions; saved custom mappings persist.

Double-click a MIDI item to open Piano Roll, or right-click empty space on a
normal track and choose Add MIDI. Draw notes, drag selected notes, resize their
edges, or right-drag a selection box. Ctrl+A selects the visible channel's notes;
Shift bypasses snapping. Velocity, quantization and undo/redo retain the shared
Mac note format. Use track FX to load the instrument used for playback.

Advanced > Timeline includes cleanup of files removed from the timeline.
It saves the project, clears undo and removes only remembered owned media.
Current/sibling references are protected; recovery backups retain their media.

Remote
Click Remote to enable/disable the host; right-click it to configure separate
four-digit Director and Notices PINs. Observers cannot edit or control playback.
Open Remote on the iPad and choose this PC on the same local network. Incoming
connections require the appropriate Windows Firewall permission for that network.
Audio remains on the PC. The protocol uses the same encrypted connection and
typed state/messages as Mac; actual iPad interoperability still needs verification.

grandMA2
The grandMA2 button is immediately left of Resolume.
The map reserves Sequence, Executor and Timecode destinations by stable region ID.
Removed regions keep their reservations. Partial exports keep the original numbers.
Choose a destination and export. Copy macros/ and import/ to the grandMA2 import
directory. Import and execute only the macro 00-Importar tudo - [project]-macro.xml.
Configure a virtual MIDI output in CatLive and the matching input in grandMA2.
MTC uses 30 FPS and follows the main cursor, including promotion of Sub Play.
Save the .jl after editing or exporting the map.

Build
Run Windows/build.ps1, or the desktop build catlive windows.bat launcher.
Requires Visual Studio 2022/2026 C++ desktop tools and Windows SDK.
Dependencies and builds default to LocalAppData/CatLiveBuild to avoid long paths.
The pinned JUCE source is downloaded on the first build if not cached.
The script runs CTest and creates a portable x64 ZIP after successful tests.
Use -Installer with Inno Setup 6 installed to also create Catlive-[version].exe.
For a paired desktop release, run build catlive.bat at the repository root.
It sends CatLive changes to GitHub Actions, builds Windows and macOS, tests actual
encrypted document exchange and publishes both installers together after success.
Git, Node.js 22, GitHub CLI and an authenticated GitHub session are required.
The existing build catlive macos.command starts the same paired workflow on Mac.

Validation
CatLive.exe --self-test [absolute-results-directory]
CatLive.exe --visual-test --capture [absolute-image.png] --quit-after-capture
The latter uses a clearly labelled silent visual fixture and tests editing actions.
Normal launches never load demonstration material automatically.

Distribution
This is a development build. See validation-status.txt for actual verified coverage
and remaining Mac parity work. Check THIRD-PARTY-NOTICES.txt before distribution.

CatStemSeparation 5
Insert CatStem on one track or audio item and use the five source faders, Mute,
Solo and bypass. The mix is saved in the project and remains active when its
editor closes. The installer includes the model and inference runtime.
Preparing the model does not block the audio callback. If inserted during Play,
it activates automatically after preparation, with initial latency priming as on
Mac. Real-time availability depends on the measured processing speed of the
computer. Windows uses 8192-frame hops and compensates a 66150-frame delay at 44100 Hz
(1.5 seconds) across audio routes. Mac keeps its existing, shorter latency. This effect is not
intended for zero-latency microphone monitoring.
