# CatLive WindowsNative foundation

This directory contains the replacement foundations for the Windows application without JUCE: shared project/transport code, native document actions, audio-file decoding, SF2 synthesis, Rust device I/O and reusable browser UI controls.

It is **not yet a complete replacement application**. Building this directory produces libraries, tests and command-line examples. It does not install a new CatLive window, migrate the complete interface, or connect a finished playback/recording engine to the devices. The existing application under `../Windows/` is a separate implementation and still contains JUCE until the replacement is integrated and validated.

## Implemented boundaries

| Area | Available here | Integration still required |
| --- | --- | --- |
| Projects | Mac-compatible JSON codec, validation, document/session state, undo/redo, action dispatcher and Rust/C++ bridge | Complete application open/save/import flows, media packaging and UI bindings |
| Track duplication | Independent IDs, folders/stereo pairs, clips/MIDI, routing and opaque FX states; one document edit | Capture live external-plugin state before dispatching a duplication in the eventual host |
| REC Multitrack | Factory for 1–128 mono tracks, default 32; inputs 1…N, Master output, monitoring off; transient armed IDs returned separately | Real capture/file writing and hardware verification; creating a template does not establish device capability |
| Audio files | WAV/AIFF/FLAC/MP3 reading and accurate random access using dr_libs | Worker streaming, buffering, playback graph and waveform delivery |
| SF2 | TinySoundFont renderer shared with the Mac implementation | Connect project MIDI scheduling, voices and the final mixer |
| Device I/O | CPAL output/input configuration, callback lifecycle, bounded input buffering and midir ports | Implement the production `RealtimeEngine` adapter, clock/latency mapping, monitoring, recording and DSP |
| Browser controls | Frosted context menus, area-sensitive selection, movement lock, REC settings and creation step | Attach to the real window, project views, session actions and preferences |

`src-tauri/` is the anticipated host directory name. Its current Cargo manifest builds a Rust library and examples; it has **no Tauri dependency or application window**. DOM fixtures in `Tests/` exercise components and are not the product interface.

The device host currently permits at most **32 hardware channels** per endpoint. The project factory's 128-track limit is a document limit, not a promise of 128-channel recording. Audio-file opening/indexing, JSON editing, validation and history belong on worker/control threads, never inside the audio callback. The optional `audio_probe` only opens the default output briefly and renders silence; it does not record microphone data or play a project.

Mac item-import parity is still incomplete. The item fields `fadeTimelineStart`, `fadeTimelineDuration` and `automationSourceOffset` are not yet connected through the typed Core/action bridge. Preserving project JSON is not equivalent to applying those fields in playback/editing. Integrate their import, item actions and rendering/audio behavior before claiming complete Mac project parity.

## Build and tests on Windows x64

Prerequisites:

- Visual Studio C++ x64 build tools and a Windows SDK.
- CMake 3.24 or newer, with CTest; the Visual Studio CMake component is supported.
- Rust stable with the `x86_64-pc-windows-msvc` toolchain.
- Node.js for the independent UI tests (Node 22+ for the browser CDP harness).

From this directory in PowerShell:

```powershell
.\build-core.ps1
```

The script finds Visual Studio and imports its x64 developer environment before running CMake **and Cargo**, builds the C++ Release targets, executes CTest and then runs `cargo test --locked`. This also supports starting in ordinary PowerShell instead of a preconfigured developer shell. Failures stop the pipeline. Build outputs default to `build/cpp` and `build/rust`; `CARGO_TARGET_DIR` and `CARGO_INCREMENTAL` are restored when the script exits. The imported compiler environment remains in that PowerShell process.

Optional external fixtures exercise real SF2 rendering and MP3 random access:

```powershell
.\build-core.ps1 -BuildDirectory C:\CatLiveBuild `
  -SoundFontFixture C:\Fixtures\test.sf2 `
  -MP3Fixture C:\Fixtures\test.mp3
.\build-core.ps1 -ProbeAudio
```

Use media you are entitled to test; no user recordings or commercial SoundFonts are distributed here. Without these arguments, the deterministic audio-file tests still run; the SF2 fixture target and external MP3 checks are omitted. ASIO is an opt-in Cargo feature and is outside this default build and its notice inventory.

UI unit tests run separately and do not require installing npm packages:

```powershell
npm run test:ui
```

`Tests/browser-controls.html` and `Tests/browser-controls.mjs` additionally test actual Chromium/Edge focus, keyboard, pointer and menu behavior through CDP. They require an isolated browser serving that fixture; simulated fixture callbacks are intentionally separate from production bindings. Passing component tests does not establish visual parity for the complete CatLive application.

Read-only host examples, run from `src-tauri/` in the same developer environment:

```powershell
cargo run --locked --example device_report
cargo run --locked --example project_audit -- C:\Projects\example.jl
```

The project audit accepts the saved .jl project (including encrypted .jl on Windows), validates it and reports counts without saving changes. Plain JSON documents are also supported; a ZIP archive must first go through the application's archive reader.

## Portable REC template check

After building, generate a document with real UUIDs for the existing Mac decoder:

```powershell
.\build\cpp\Release\ProjectCreationTests.exe --write-fixture C:\Fixtures\recording32.json
```

The factory uses the same `Project` schema: one 300-second song at 120 BPM, a setlist referencing that song, standard gray tracks, sequential mono inputs, Master outputs and no format override. Arming belongs to the session and is returned as `armedTrackIDs`, rather than inventing a persisted `armed` field. This fixture has also been decoded, validated and round-tripped with the existing macOS Swift `Project` implementation without opening the GUI. That verifies persistence, not live recording.

## Dependencies and redistribution

The default foundation does not link JUCE or require a JUCE license. C++ dependencies are nlohmann/json (MIT), dr_libs (MIT-0 option) TinySoundFont (MIT) and Steinberg VST3 pluginterfaces (MIT). Rust device I/O uses CPAL (Apache-2.0), midir (MIT) and their pinned transitive dependencies. `audio_thread_priority` is MPL-2.0; its complete upstream source archive is included, matching the Cargo checksum. These dependency licenses have no per-copy royalty, but their license and source-distribution terms still apply.

See [THIRD-PARTY-NOTICES.txt](THIRD-PARTY-NOTICES.txt), the license files in `ThirdParty/` and the source metadata beside them. Preserve those files when packaging the replacement. Inter is the intended shared font; its files and SIL OFL 1.1 license are in `../Resources/Fonts/Inter/`, and the final UI package must include that license when embedding the font. No complete installer or redistribution package is produced by this build.

## VST3 host foundation (Windows only, not connected to the shipping UI yet)

`CatLiveVST3` loads Windows x64 VST3 modules directly through Steinberg's MIT
interfaces. `VST3Probe module.vst3 report.json --process` runs in an isolated
process, verifies PCM processing, captures state, destroys the processor and
restores it. Add `--editor` on an interactive desktop to exercise the native
HWND editor. Do not run DLL scanning on the audio thread.

The Kontakt 7 scan/processing/state probe passed on the user's Windows PC.
The native editor probe also passed (Kontakt HWND 1023x637) on the interactive desktop; a service/SSH desktop is not an editor test environment. Application integration is in progress. This
foundation does not enable the external FX menu in the existing application.
Pending production work includes instance lifetime through undo/save, bounded
scanner timeouts, plugin restart/latency compensation, both playback heads,
complete MIDI routing and editor scaling/lifetime handling.

## CatStem worker validation

`StemSeparation/prepare.py --output <new-directory>` creates an isolated Python
runtime with pinned package versions and hash-verified Python/model downloads.
It does not modify the user's Python installation. The Windows Torch backend
uses the same CST1 framing, epochs, bounded queues, crossfade and five-source
mixture consistency as the Mac worker. It must pass its measured realtime
deadline and sustained throughput check before accepting realtime processing.

The Windows application connects this worker to track/item FX, with five saved
source gains, mute, solo, bypass, undo and export. Model loading and IPC run off
the audio callback. The audio callback uses bounded queues; it never waits for
inference. The verified runtime and FP32 graph are included in ZIP/installer.

OpenVINO uses an available Intel GPU or CPU, falling back to the pinned Torch
backend if needed. Warmup checks sustained throughput before admitting realtime
processing. A device that misses the deadline retains original audio and exposes
an error in the editor; it must not slow down playback. One realtime inference
worker is admitted at a time. Offline export has its own worker lease.

The fixed model delay is 66150 frames at 44100 Hz (1.5 seconds), rescaled to the
host rate. Parallel tracks, sends, direct hardware routes, the audible cursor,
and exports compensate for this delay. A newly loaded worker is admitted at a
stopped transport boundary so enabling it cannot jump a running show. This is
not zero-latency microphone monitoring.

Validation commands:
  CatStemProcessTests.exe python.exe stream_windows.py model.th --realtime
uses the actual production model for 30 seconds each at 44100 and 48000 Hz,
checking finite PCM, reconstruction, deadlines and underrun/overrun counters.
  Windows/scripts/test-catstem-runtime.ps1
uses a separate identity worker to verify exact samples through groups, sends,
hardware routing, both heads, loops, part jumps, seeking, bypass and export.
The identity tests never replace or modify the production worker or model.
