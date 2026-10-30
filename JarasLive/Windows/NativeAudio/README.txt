CatLive native Windows device backends

The desktop has an opt-in native device owner (CATLIVE_NATIVE_DEVICE_HOST=ON,
with an external CATLIVE_ASIO_SDK). The default release configuration still uses
the legacy owner until the native integration completes hardware qualification.
NativeAudioDeviceHost keeps the existing settings/MIDI control API, but sends
audio directly from the native backend through CallbackHub to AudioEngine.
AudioDeviceManager's mixing callback and callback lock are not in that path.
This does not replace the UI or enable parallel/anticipative graph processing.

WASAPI
  WasapiDevice owns a dedicated MTA worker and event-driven audio service loop.
  Shared, IAudioClient3 low-period shared, exclusive and loopback are explicit
  modes. Negotiated channels/rate/period are reported; no silent device fallback.
  One direction per WasapiDevice instance. ClockedDuplexDevice combines capture
  and render through DuplexInputBridge; only the output clock advances the graph.
  Input uses a prepared SPSC ring and interpolated 64-tap band-limited resampling
  with slow, bounded clock-drift correction. Capture gaps prime with zeros, never
  old samples, and never block output. Physical input maps and added latency are
  reported. ASIO uses its synchronized driver callback without this bridge.

ASIO
  AsioDevice calls IASIO directly. One live driver is supported per process.
  Control calls and destruction use the opening STA thread. Sample buffers and
  conversion planes are allocated before start. Driver callbacks only convert,
  process and report bounded atomic state; reset/rate changes require reopening
  on the control thread. DSD, aggregation and direct monitoring are unsupported.
  Driver stop/dispose must honour the ASIO callback lifetime contract.
  The driver owns its callback thread; MMCSS registration is not inferred from
  its driver name. Production scheduling integration still needs validation.

Building
  cmake -S Windows/NativeAudio -B build/native-audio -A x64
  cmake --build build/native-audio --config Release
  ctest --test-dir build/native-audio -C Release --output-on-failure

  Optional direct ASIO build:
    -DCATLIVE_ASIO_SDK=<external ASIOSDK root>
  SDK headers remain outside this repository. The downloaded SDK's common/
  LICENSE.txt requires a signed Steinberg agreement before publishing under
  its proprietary licence; the alternative licence is GPLv3. No agreement is
  accepted or SDK content redistributed by this build configuration.

Hardware probe (silence only; never part of automated CI):
  CatLiveNativeAudioProbe --enumerate
  CatLiveNativeAudioProbe --enumerate-asio
  CatLiveNativeAudioProbe --smoke-shared
  CatLiveNativeAudioProbe --smoke-low-latency
  CatLiveNativeAudioProbe --smoke-exclusive pcm16

The smoke tests verify callbacks, zeroed outputs, stop quiescence and restart
on the default render endpoint. The optional pcm16 argument requests that wire
format explicitly; unsupported exclusive formats fail instead of falling back
to shared mode. Conversion tests cover sample byte
layouts, channel mapping, bounds and allocation-free processing. These checks
do not certify driver stability, professional interface latency, duplex capture,
or the complete CatLive graph under load.

Local Windows validation, 2026-10-29:
  - Shared and IAudioClient3 shared-low-latency silent playback passed at
    48000 Hz, stereo, including stop quiescence and restart with MMCSS active.
  - Exclusive PCM16 silent playback passed at 48000 Hz, stereo with the same
    lifecycle checks. The endpoint rejected exclusive float mixer format;
    requesting PCM16 explicitly succeeded without changing device mode.
  - PCM conversion, ASIO conversion and simulated ASIO lifecycle CTest targets
    all passed. The simulated driver never opens a physical ASIO device.

Native host integration keeps lifecycle notifications on the control thread,
publishes project clients at block boundaries and waits for removal only on the
control thread. A lost callback is joined before its client can be destroyed.
Channel expansion remains in AudioEngine; the host hub therefore uses a packed
identity map, avoiding double mapping. Device reset/rate notifications stop on
control and require explicit reopening; automatic recovery and broader hardware
qualification remain pending. Never describe this as a completed parallel engine.

Local integration validation, 2026-10-30 (opt-in native host executable):
  - Real shared WASAPI output continued while the manager callback lock was held.
    Adding/removing clients did not restart the device; removed clients were not
    called again. Device stop/reopen restored the remaining clients.
  - Real duplex input/output passed finite-input, silent-output and latency checks.
  - Three real AudioEngine clients passed Stop/Play, prepared graph replacement
    and destruction of another client while using the native device owner.
  - Regression filters passed stereo rendering/Sub Play/loops, prepared capture,
    immediate Play after recording, concurrent FX edits and Auto across six tabs.
  - All seven standalone Windows native CTest targets passed. Duplex ring and
    clock tests also passed local ASan/UBSan and TSan; device rollback passed
    ASan/UBSan. These are not physical ASIO hardware qualification or proof that
    arbitrary third-party plugins never allocate in their own processing calls.

Prepared native callback hub (connected in opt-in native host builds)
  CallbackHub accepts raw noexcept client callbacks and optional control-owned
  lifetime references. It prepares input and per-client output scratch once,
  expands packed device inputs to physical channel numbers, sums clients in
  publication order, and repacks physical outputs. Unmapped/null inputs are
  silent. Input/output aliasing is supported. Limits are 128 physical channels,
  65536 frames and 64 clients; unsupported configurations fail before playback.
  This is sequential mixing, not parallel graph or anticipative FX processing.

  An atomic pending/current/retired ownership mailbox publishes whole immutable
  client lists at block boundaries. New pending lists coalesce on control.
  Callback ownership transfers never allocate, delete, retry or wait. When a
  retirement awaits collection the existing list keeps rendering; publication
  contention does not create a silent block. Control must call collectRetired
  regularly so a later pending update can be adopted. Snapshot storage is
  bounded to active + pending + retired (plus a temporary during publication).

  Construct/control/destroy on one non-reentrant control thread. Device stop
  must join all callbacks before resetAfterStop or hub destruction. Retained
  client owners are released only on that control thread. Raw context pointers
  without a lifetime reference must remain valid through stop and reset. A
  callback must itself meet realtime rules; publishing an AudioEngine callback
  here does not remove the engine's existing locks or lifetime dependencies.
  Invalid/overlapping blocks are rejected and counted without touching storage
  beyond prepared limits; as required by AudioDevice, the device must clear its
  outputs before invoking the hub. The hub diagnoses bad callbacks but cannot
  safely repair an adapter that passes invalid buffers or concurrent callbacks.

  Portable verification:
    cmake -S Windows/NativeAudio/CallbackHubTests -B build/callback-hub
    cmake --build build/callback-hub
    ctest --test-dir build/callback-hub --output-on-failure
  Optional separate builds: CALLBACK_HUB_SANITIZE=ON for ASan/UBSan or
  CALLBACK_HUB_THREAD_SANITIZE=ON for TSan. Release, ASan/UBSan and TSan passed
  locally on macOS, including 10000 concurrent publications, mapped/aliased
  inputs, independent client scratch, deferred control-thread reclamation,
  invalid bounds, overlap rejection, restart, and zero callback allocations or
  deallocations. These are bounded synthetic tests, not a full DAW load test.

  Real WASAPI shared probe (silence only):
    CatLiveNativeAudioProbe --smoke-hub-shared
  It adds/removes/replaces silent clients during device callbacks, verifies
  stop/restart, counts all context destruction on control, and audits C++ heap
  allocation/deallocation only inside the hub/client callback scope. Its
  replacement allocation operators belong only to the diagnostic executable,
  never to the native device library or shipping CatLive. It does not intercept
  direct malloc/free inside arbitrary third-party DSP or certify the graph.

  Windows validation, 2026-10-29: all four native CTest targets passed. The
  real shared-mode silent hub probe completed 282 callbacks / 539 client calls,
  created and reclaimed all 81 client owners on control, counted zero C++ heap
  allocations/deallocations in callback scope, and reported MMCSS active.

Production graph publication (2026-10-30)
  AudioEngine live mutations now use ordered prepared tickets: native parameter
  previews, whole FX chains, MIDI item sequences, item timing/pitch/presence,
  region pitch, tempo maps, track routing, stem admission/retirement, fadeout and
  complete graph adoption. Allocation and topology matching happen on control;
  audio swaps prepared storage and publishes completion. Displaced resources
  are reclaimed on control, preserving external-plugin destruction dispatch.
  Latency-history matches are prepared before publication, not searched during
  the callback. Tempo history remains in canonical coordinates: a precomposed
  piecewise-affine map swaps once; per-frame lookup preserves loops and seeks
  without traversing the entire latency history on every BPM edit.

  Synchronous callers wait on control for the normal render owner. They do not
  take the device callback lock or take over its consumer. A pending edit may
  be cancelled on device failure/timeout; its ticket remains alive until audio
  consumes it. An edit that already started must finish its bounded commit.
  Detached/offline engines have no competing consumer and drain synchronously.
  Manual/native drivers must declare external render ownership before starting
  and clear it only after joining their callback. This flag does not itself
  integrate a native backend with production device selection or MIDI routing.

  Graph adoption retains both source clocks and unchanged DSP/delay histories.
  Old continuous mixer snapshots are consumed before structural FIFO commands,
  so the outgoing project's pending mute/gain cannot affect the new graph.
  No queue reset, owner destruction or admission gate that silences a live
  block is used at adoption. Rejected sample-rate/recording changes leave the
  graph intact. Public synchronous preparation stages an isolated replacement
  when a render owner is attached instead of restarting the device callback.

Production track telemetry ownership (implemented prerequisite)
  Core/Audio/MeterState.hpp has no JUCE or renderer dependency. The production
  AudioEngine prepares an independent shared payload per bus and a control-side
  ID registry. Its meter/FX/held-peak getters no longer traverse the DSP buses.
  A retained const trackMeterState handle can outlive a retired graph or engine;
  it remains the frozen old generation and must be reacquired after a graph
  change. The callback accesses the payload directly and does not copy or
  release shared ownership. Floats are required to be lock-free on the target.
  Registry access and graph preparation/adoption are serialized on control, not
  permitted concurrently from arbitrary UI/background threads. The scalar
  atomics may be read on a retained handle without accessing a DSP object; they
  are deliberately approximate level readings, not a coherent multi-field frame.
  PeakHold preserves existing maximum/reset behaviour and its CAS retry loop;
  this change does not claim a wait-free full audio callback. Armed/fade state,
  editor handles and media diagnostic readers still require serialized control
  access around acknowledged graph publication. Device dispatch is still owned
  by AudioDeviceManager; this does not certify arbitrary third-party DSP.

  Windows verification: the retained-meter regression passed through live
  adoption, retired-bus destruction, track deletion and engine destruction.
  The 17-test meter/parameter group, two peak readout tests and five native
  frontend tests passed after the rebuild. The existing dynamics preview test
  depends on the earlier Trigger sample fixture; running it alone in an empty
  output folder fails on both the previous and new executable. The group was
  rerun in a fresh directory after its normal Trigger fixture setup.

Production command publication (implemented prerequisite)
  Core/Audio/RealtimeCommandQueue.hpp replaces the production AbstractFifo and
  its callback-lock overflow drain. A serialized control producer publishes
  ordered, trivially copyable commands into pooled blocks. The audio consumer
  never allocates, frees owners, waits, retries or calls back into the producer.
  The callback drains at most 1024 commands per render chunk; offline/control
  drains finish the complete queue before rendering or replacing graph indices.
  This budget limits command dispatch, not the cost of the existing handlers.

  Storage is preallocated for the warm pool and can grow on control if command
  publication outpaces consumption. Queued memory is NOT globally bounded;
  preserving all ordered commands during a stopped device requires retaining
  that backlog. Consumed blocks are reclaimed on subsequent control pushes or
  explicit collection, retaining only a small spare pool. A callback-published
  block position protects ownership; reset/destruction require both sides to
  be quiescent. Live graph edits now use acknowledged tickets; only detached engines
  may drain on control. This is not the completed native driver migration.

  Portable tests in CommandQueueTests cover 500000 concurrent ordered commands,
  overflow, finite dispatch budgets, block reuse, reset/restart and zero C++
  allocations/deallocations in queue-consumer scope. Release, ASan/UBSan and
  TSan passed on macOS; the standalone Windows/MSVC test also passed.

  The production Windows Release build passed the overflow regression with
  5000+ queued commands while another thread held the device callback
  lock. Realtime consumption retained its finite budget; offline consumption
  applied the final gain/mute and ordered Stop/seek/Play before rendering.
  Armed-input monitoring and retained-meter graph-lifetime regressions also
  passed in that executable. These targeted checks do not validate replacing
  the current device owner with the standalone native backends.

Prepared resource edits (production integration in progress)
  Core/Audio/PreparedAudioEdits.hpp owns move-only prepared work on control.
  Raw tickets share the ordered AudioEngine command stream. After a noexcept
  edit swaps its resources at a block boundary, a completion atomic allows
  control to destroy the ticket and displaced resources. Collection runs on
  subsequent control publication or graph replacement; an idle engine may
  retain its final completed ticket until then or until shutdown. Device stop
  must exclude the consumer before discarding queued tickets or their owners.
  The mechanism does not make arbitrary plugin code realtime-safe.

  Metronome sound/output configuration and generated-click timing now use this
  path instead of the callback lock. Preparation resolves targets; structural
  graph replacement drains pending edits before destroying those targets.
  The production Windows tests passed publication with the device lock held,
  output patch/PCM verification, settings retention across project replacement,
  the existing generated-click test and the command overflow regression.

  Native FX parameter/dynamics previews also publish prepared snapshots on the
  command stream. Recording-worker previews stay on control. Full FX replacement
  follows earlier snapshots on the same ordered stream, preventing an old drag
  value from overriding a newer committed value.

  Core/Audio/RealtimeLatestValue.hpp is a preallocated SPSC triple buffer for
  coalescible mixer state. Each bus and the Master retain only the latest complete
  volume/pan/mute/solo/routing-control snapshot. Audio consumes at most one per
  bus per block. Transport, item edits and resource tickets remain ordered in
  the FIFO; they are not overwritten as continuous fader controls are.
  Both sides have exclusive ownership of their own triple-buffer slot, with a
  shared atomic middle slot. Graph replacement drains the old snapshots before
  retiring their buses. Atomic operations are compile-time required lock-free.

  Windows Release verification after mixer coalescing passed all nine targeted
  tests: stereo playback/mixer/Subplay/seek/loop (including Stop after a command
  backlog), live FX replacement, prepared FX previews and commit ordering,
  prepared metronome edits/project replacement, native parameter commits,
  post-FX recording previews, delay-history preservation, audible native DSP
  previews, and ordered command overflow with realtime/offline consumption.
  The playback fixture ran first in the same output directory as live FX
  replacement, which requires its generated Audio/signal.wav.

Recording publication and disk output (2026-10-30)
  RealtimePCMQueue is a fixed planar SPSC ring; the callback only copies a whole
  block and advances atomic cursors. BufferedAudioWriter polls it on the disk
  worker and performs encoding, file writes and header finalization there. It
  no longer notifies a TimeSliceThread once per captured track/block. Overflow
  rejects the complete block and records the existing diagnostic; storage is
  not grown from audio and overflow does not silently pretend to be recorded.
  finish joins the writer client before draining remaining PCM and finalizing.

  RealtimeBorrowedPointer gives one callback a raw block-scoped capture lease.
  Control prepares capture/FX/files before publishing. Stop withdraws capture
  and waits on control for the last admitted block, while ordinary playback
  continues. Session finalizes detached takes on its existing worker; immediate
  Play waits for usable recorded media. Live arm changes use prepared target
  vectors with an acknowledged frame boundary. The legacy single-file recorder
  uses the same borrowed lifetime and does not reattach the audio callback.

  Release Windows tests passed whole-block queue overflow and finalization,
  disk failure, PCM/MP3 encodings, live arming, pre/post fader and effects,
  exclusion of arrangement items from output takes, immediate Play and first/
  last sample preservation with the device lock deliberately held elsewhere.
  The concurrent callback harness also passed FX replacement, graph adoption
  with pending outgoing mute, incompatible-rate rejection, item edits, tempo
  continuity, routing, delay histories and ordered command overflow. Portable
  ASan/UBSan, TSan and Windows/MSVC tests cover cancellation/publication races,
  capture lifetime, PCM transfer and canonical timeline mapping, with zero C++
  new/delete in their audited callback scopes. These are targeted regressions;
  they do not certify malloc/free in third-party plugins or a whole DAW load.

  Remaining device-host work: native production selection/lifecycle and
  reconfiguration, physical duplex/clock coordination and recovery, and
  integration of the prepared callback hub across project tabs. Parallel and
  anticipative processing are not enabled. The direct native backends remain
  standalone until those paths are integrated and tested on real devices.

Apple prepared file playback
  Apple/Bridge/JarasPreparedClip.inc also needed realtime ownership work even
  though its device/graph host already uses AVAudioEngine. It now uses the
  shared Core/Audio/RealtimeRunState.hpp for explicit Stop/prepare/Start:
  control waits for an admitted callback to finish; the callback never takes
  the old preparation mutex. The control mutex still serializes preparation.
  This lifecycle is not used to silence rendering around live parameter edits.

  Core/Audio/SingleReaderSlots.hpp replaces atomic shared_ptr page reads.
  The single reader announces a bounded read scope and uses immutable raw
  pointers. The serialized decoder owns current and retired pages, collects
  them only after observing reader quiescence, and allocates retirement slots
  before publication. Sequential consistency is deliberate across the reader
  announcement and page pointers. The page objects are not a fixed-size pool;
  allocation and reclamation happen on the decoder/control side. All readers
  must finish before cache destruction. This does not certify third-party FX
  or the rest of AVAudioEngine as allocation-free.

  CommandQueueTests exercises concurrent page replacement/readers, edit
  retirement, explicit start/stop and zero C++ new/delete in the tested audio
  scopes. ASan/UBSan and TSan passed locally; Windows/MSVC passed too.
  scripts/test-prepared-clip-audio.sh passed actual AVAudioEngine manual render
  checks at 44.1/48 kHz and 64/512 frames, original PCM, pitch/rate changes,
  Stop/seek, streaming over multiple page generations and a loop across
  colliding cache positions. The complete macOS Release app also compiled.
