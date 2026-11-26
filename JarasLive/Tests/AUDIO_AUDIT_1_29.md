# Audio audit — CatLive 1.29

Date: 2026-11-06. Scope: release Windows engine, shared macOS/iPad playback,
Apple audio units, MIDI, streaming, recording, plugins and device lifecycle.
Minimum supported Mac remains macOS 12.0, including Intel x86_64.

## Evidence status

The user authorized local compilation and tests on 2026-11-06, superseding the
earlier no-local-build restriction. Local execution is on Apple Silicon arm64,
macOS 27.0 (26A428), with a macOS 12.0 deployment target. The universal Release
application compiled for arm64 and x86_64; Intel execution and physical macOS
12.7.6 validation remain pending. Rosetta is unavailable on this host. No app was
installed/restarted, no device settings changed, and nothing was sent to GitHub.
No claim of zero dropouts is made.

Local validation results:

- Core CMake/CTest: 6/6 passed.
- Native EQ, dynamics, track/group/master/item FX, automation, media worker,
  editing continuity and sample-epoch checks passed. EQ/dynamics and effect
  transfer/RTA checks were also run with the production DSP `-O3` setting:
  36 EQ cases per rate at 44.1/48/96 kHz, residual RMS approximately 2e-9.
- Prepared PCM, 24-stem/high-rate streaming, failed-source retry, mobile driver,
  output mapping/connection, MIDI, metronome and SF2 suites passed.
- Live invalid-media isolation and strict export/retry passed at 44.1/48 kHz,
  with legacy/current routing and cold/warm preparation.
- Mobile queue synchronization, phase and Trigger/Gate passed at 44.1/48 kHz.
- FX editing refresh passed (234 revisions, 38 RTA, 59 meter and 29 spectrogram
  updates in the two-second fixture).
- VST3 unaligned-identifier regression passed ASan+UBSan. Ten full VST3 runs
  passed with ASan+UBSan on the host and UBSan on the disposable plugin. Full
  ASan instrumentation of repeatedly unloaded plugin images intermittently
  fails inside this macOS 27 loader; an independent Foundation-only control
  reproduced it. The temporary diagnostic workaround is not in production or
  CI, so fully instrumented plugin coverage remains qualified on this host.
- One initial full `AudioRenderTests` run produced zero PCM during a unified
  region Subplay promotion. Minimal and instrumented reruns passed, as did a
  comparison using the original HEAD playback source and four complete current
  uninstrumented runs (44.1/48 kHz, two passes). No assertion was relaxed and no
  production change was made to conceal it. The initial failure remains
  unexplained, so the audit is not an unconditional release certification.

An in-flight test script edit changed Bash's read offset and caused a shell
failure after completed assertions. The final sample-epoch fixture was rerun
separately and passed. This was a test orchestration error, not application PCM.
Logs are retained locally in `/tmp/catlive-129-*.log`.
The final app is `build/mac-review/Build/Products/Release/CatLive.app`, unsigned
for local review. It includes both arm64 and x86_64; its 126 Mach-O files (127
architecture slices) passed the deployment audit against macOS 12.0. The app was
not opened or copied into Applications.

## Corrections

| Area | Confirmed risk | Change | Pending regression |
| --- | --- | --- | --- |
| Windows routing | Callback deduplicated destinations into a 513-entry stack array without a matching project limit; repeated searches were quadratic | Traverse unique, latency-compensated routes prepared outside the callback | `Windows/Source/Tests.cpp`: 520 destinations with duplicate parent/send/receive connections |
| Apple device binding | Checking `isRunning` before rebinding could return success after the binding operation stopped the engine | Confirm binding before the fast path and check the engine after startup | Physical output rebinding, particularly macOS 12 Intel |
| Apple scheduling | Failure before enqueue left reserved voices that never started; one invalid source could abort healthy stems | Roll back uncommitted reservations, isolate live media failures, continue prewarming valid media, retry after Stop/edit; keep export failures explicit | `PlaybackMediaIsolationTests.swift`, 44.1/48 kHz, current/legacy routing policies, cold/warm sources and recovery |
| Apple VST3 | Preparing a large parameter batch used quadratic searches inside processing | Append directly into preallocated parameter queues; use a prepared ID index for individual edits | `VST3/StateStreamTests.mm`, 32,768 parameters, unordered IDs, coalesced edits and next-block state |
| Shared VST3 SDK | Identifier comparison cast byte-aligned TUID pointers to `uint64*`; UBSan confirmed a misaligned load | Compare the same 16 bytes with `std::memcmp` | `VST3/UnalignedUIDTests.cpp`, all 64 alignment pairs and every changed byte, passed ASan+UBSan |
| Apple state lifetime | Allocating retirement storage after publication could release state still used by a reader if allocation failed | Reserve retirement ownership before publishing VST3 chains, tempo maps and MIDI sequences | VST3 state/concurrency suite and MIDI sequence suite; allocation-failure path reviewed, not fault-injected |
| Apple numerical state | Direct sources lacked the effects' denormal protection; plugin changes must not escape a block | Shared Intel FTZ/DAZ and ARM FPCR guard across PCM, SF2, VST3 and metronome; restore the full original control word | Nested guards including entry with flush already enabled and a simulated plugin change |
| Apple metronome | Hazard acquisition retried without a bound while the UI published programs | Atomic reader admission, quiescent retirement and preservation of still-sounding click tails | Concurrent preset publication and tail lifetime in `MetronomeRenderTests.mm` |
| Apple idle preparation | Opening media, converting movie audio and reading onsets blocked MainActor; old requests could outlive the project | One cancellable serial worker for independently owned readers/buffers, project generation checks; conversion locks only cache publication | `AudioMediaPreparationTests.swift`: worker bounds, cancellation, failure recovery and project replacement PCM |
| Apple streaming | One cache could hold the worker for six reads or wait on a preparation lock; fixed lookahead omitted the spectral cursor at high rates | Try-lock busy decoders, one page per cache per sweep, immediate fair continuation, failed-read backoff and rate-dependent lookahead | `PreparedClipAudioTests.swift`: 24 stems, 192 kHz/32×, stream/loop continuity |
| Apple preparation retry | A failed new source could retain old successful preparation metadata and be reused or started | Explicit preparation-valid state, cleared before a fresh attempt and set only after successful prime | Two injected read failures, forbidden start, then correct-source PCM after repair |
| Windows VST3 | Dirty batches and ID lookup were quadratic; 2048 extra queue slots were insufficient for 2080 MIDI mappings | Preallocated ID index and slots for actual hidden mappings | 32768 parameters, 2080 MIDI mappings, coalescing and block reset |
| Windows recording | Device input channel count could differ from the writer's fixed count after restart | Bound reads by supplied channels and write silence for absent inputs | Mono → zero inputs → stereo without shortening the recording |
| Native FX UI | EQ response rebuilt biquad coefficients per pixel; each knob event reapplied all track chains | Prepare response coefficients once; apply preview only to the target and its recording mirror | Response equivalence and unrelated automation/PCM preservation |
| EQ RTA | PCM snapshots were captured before checking worker availability; strict timer gating could skip alternating ticks | Lazy capture, bounded rate-map cache and timer-jitter tolerance | Busy capture rejection, rate-map parity and existing UI refresh fixture |
| Native DSP | EQ invalid dry input survived its recovery blend; compressor/reverb invalid values could poison persistent state | Contain invalid samples and Float32 overflow; validate compressor/reverb parameters; preserve valid transfer math | `EQIntelStabilityTests.swift`, `DynamicsStabilityTests.swift` |
| Reverb | Rate/room/decay/filter exponentials and delay lengths were recomputed every block | Cache render-owned values until their inputs change | PCM parity across block sizes, settings changes and reset |

Apple engine fixes and regression sources are synchronized to the separate
`catlive-app-1.29` worktree. Existing app-specific CatStem model changes are
preserved. Remote clients do not render the desktop project's PCM; they control
the host. The iPad Nativo does render PCM using the shared Apple engine.

## Verified structure and remaining risks

- Core queues and Apple render scalar atomics use bounded/preallocated storage.
  Build-time assertions reject non-lock-free scalar implementations on Apple.
  PCM decoding/prefetch and recording file writes are outside their callbacks.
  This does not prove that framework or third-party plugin internals never lock.
- **Windows release still defaults to JUCE device management.**
  `Windows/CMakeLists.txt` sets `CATLIVE_NATIVE_DEVICE_HOST=OFF`; the release
  builder does not override it. The native ASIO/WASAPI implementation is optional
  and requires an externally supplied ASIO SDK. The diagnostic field
  `nativeDeviceHost` now identifies the path actually running. The native backend
  was not enabled without driver/hardware validation.
- Windows prepares sources in workers, but voice/bus/plugin DSP is still serial
  within its callback. It is not a parallel DSP graph or anticipative FX engine.
- Apple `StemAudioPlayback` is `@MainActor`: rendering is separate, but scheduling
  new media and jumps still relies on the main thread and about two seconds of
  lookahead. Idle reader/onset work now leaves MainActor, but a live cold cache
  miss and `JarasPreparedClip.prepare` (prefetch and FFT priming) still run there.
  Moving the live prepare blindly would introduce contention with Play/teardown.
  A long main-thread stall can still exhaust the scheduling horizon.
- Movie conversion no longer holds a global lock for the whole conversion.
  The serial idle/prepared-PCM workers still cannot preempt an individual stuck
  physical file read. Cloud or slow-storage stalls remain a limitation.
- Native FX preview still validates/serializes the target's settings for each
  editor event. The expensive full-mixer traversal has been removed, but editor
  responsiveness under large-project load still needs measurement on Intel.
- Streaming caches and recording queues are finite. Cloud-only/unavailable
  files, storage latency, memory pressure and over-budget plugin DSP can still
  produce missing audio. Plugins execute third-party code in the render path.
- Hardware rate changes and route recreation can require a device restart.
  Source checks cannot establish continuous output through every driver change.

## CI prepared, not dispatched

- Desktop 1.29 release defaults audio/FX tests to enabled because this release
  changes the engine. Existing policy remains: disable them for later releases
  only when audio/DSP/recording/export are unchanged.
- `catlive-audio-audit.yml` runs Intel and optionally Apple Silicon. The desktop
  release calls its Intel job as a publication gate when audio/FX checks are
  enabled. It covers queues, prepared PCM, mobile clock/output mapping,
  rendering, automation, failed-media isolation, EQ, native FX, SF2, VST3 and
  metronome. Synthetic SF2 data avoids dependencies on private sound libraries.
- Audio fixture scripts target macOS 12.0. Multiple `test-audio.sh` fixture
  arguments reuse compiled bridges instead of recompiling them for each fixture.
- Apps CI runs media isolation/preparation, rolling prepared PCM, EQ/dynamics,
  effect UI, SF2, metronome and MIDI sequence checks with the audio-change
  detector in addition to mobile synchronization. Repeated fixtures reuse
  bridge compilation. DSP runners match the production EQ `-O3` compilation.
- Hosted Intel execution does **not** validate macOS 12 runtime behavior. The
  [GitHub runner catalog](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
  supplies the Intel runner used here; physical Monterey testing remains pending.

## Open issue: reported EQ hiss on Intel

The user reports continuous noise when audio passes through the native track EQ,
even with its controls untouched and editor closed. This excludes RTA drawing as
the sole explanation. Source inspection has **not established the root cause**.
The finite-value containment fix is a separate confirmed defensive defect, not
proof that it caused this report. The settled filter equations and Intel denormal
mode do not currently demonstrate a failure for valid ordinary PCM/settings.

`EQIntelStabilityTests.swift` compares actual AU output against independent
double-precision direct-form-I and analytic steady-tone references, with RTA
open/closed and callback partitions from 64 to 4096 frames at 44.1/48/96 kHz.
It includes a locally saved 10-section steep-cut preset and a separate downstream
limiter case, without personal paths or media. It passed locally on arm64,
including production DSP optimization, but did not reproduce the reported noise.
The reported hiss remains unresolved until reproduced/validated on Intel,
including a physical macOS 12.7.6 system.

## Follow-up: isolated gap misdetected as a third tempo

The open project's click reproduced a false 114 BPM marker between sustained
170 and 142 BPM sections. Measured intervals were approximately 0.352941 s,
one 0.525442 s transition gap, then repeated 0.422535 s intervals. Raw phase
fitting explained that single gap as 114.1895 BPM; public two-bar marker spacing
then prolonged it and delayed the real 142 BPM anchor by about 3.685 seconds.

Swift (desktop/Nativo) and Windows now discard only an interior one-beat
outlier outside both neighboring tempo ranges when both neighbors have at least
four beats of evidence. Raw phase fitting, introductions, multi-beat short
sections, and intermediate ramp rates are unchanged. Reanalysis of the actual
click now produces 170 -> 142 at the original measured 142 BPM entry. No project
document or audio was modified. All 34 `ClickTempoTests`, the PCM onset suite at
44.1/48 kHz, and the extracted Windows marker regressions passed. The Windows
application itself was not rebuilt locally for this follow-up.

## Follow-up: native effect output incorrectly marked as silence

A direct production-AU test reproduced a separate contract violation on arm64:
after a nonzero input, EQ, the combined item EQ/compressor, and Reverb returned
nonzero tail samples with the upstream `OutputIsSilence` flag still set. The
original test measured peaks of 0.045 for the EQ tail and about 0.01947 for the
reverb tail. This flag lets a host skip processing/mixing that buffer according
to the [Core Audio render contract](https://developer.apple.com/documentation/audiotoolbox/audiounitrenderactionflags/unitrenderaction_outputissilence).

The effect callbacks now clear a stale silence flag only when their rendered
output is actually nonzero. Audible input takes no additional scan, and truly
silent output retains the idle hint. The check is bounded, allocation-free and
lock-free. Existing stop/item gates are unchanged. Trigger no longer clears the
flag unconditionally when it is idle.

The production FX suite passed with new direct-AU checks for EQ, combined item
EQ/compressor, Compressor, Limiter, Reverb, Gate and Trigger: enabled/bypassed,
64/512-frame blocks, 44.1/48/96 kHz, flagged/unflagged identical PCM, silent idle,
tail continuation and reset cutting the tail. The full effects/RTA/editing suite
also passed. The updated bridge compiled for x86_64 with macOS 12.0 as its minimum;
this remains cross-compilation, not execution on a physical Monterey Intel Mac.
This confirmed defect is **not established as the cause of the reported Intel
hiss**. Local log: `/tmp/catlive-129-fx-silence-contract.log`.

The BPM fix was additionally checked against 36 synthetic cases per platform,
using unrelated tempo pairs (96→128, 156→112, 210→250, 135→92), faster/slower
isolated gaps, 44.1/48/96 kHz sample quantization, three timeline placements and
3/4, 4/4 and 7/4 meters. All preserve the next measured entry without a third
false tempo. The 35 Swift BPM tests passed; the actual Windows onset/marker
functions and three regression cases also passed in a standalone C++ build.
These are general detector rules; no project/music names select the behavior.

## Physical release checks still required

On an Intel Mac with macOS 12.7.6, an Apple Silicon Mac, Windows ASIO/WASAPI and
an iPad: test cold/warm Play, immediate Stop/Play across songs/tabs, queue and
Subplay transitions, loops and cut seams, recording then immediate playback,
live output/send changes, plugin preset/UI operations, and device reconnection.
Use the sample rates, channel counts and buffer sizes actually advertised by
each device. Most offline coverage uses 44.1/48 kHz, with new EQ/dynamics cases
at 96 kHz and prepared-PCM stress at 192 kHz;
it does not certify all hardware rates or buffers. Repeat under UI/CPU/storage
load and inspect PCM continuity, onset alignment, underrun/overflow counters and
callback deadlines; a moving cursor or meter alone does not prove continuity.
