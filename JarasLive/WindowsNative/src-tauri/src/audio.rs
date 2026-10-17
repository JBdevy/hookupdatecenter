//! Device I/O only. The existing CatLive engine remains responsible for mixing,
//! recording, monitoring, transport and DSP; this module does not synthesize audio.
use crate::audio_callback_gate::CallbackGate;
use crate::audio_config::{self, AudioConfig, EndpointConfig, MAX_CHANNELS, MAX_RENDER_FRAMES};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{Device, FromSample, Host, Sample, SampleFormat, SizedSample, Stream,
    StreamConfig, SupportedBufferSize, SupportedStreamConfig};
use serde::Serialize;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, AtomicUsize, Ordering};
use std::sync::Arc;

/// All methods must be allocation-free, nonblocking and must not panic.
/// render/capture are serialized. MIDI can arrive on multiple input threads and
/// must enqueue into the engine's bounded realtime queue, not mutate DSP state.
pub trait RealtimeEngine: Send + Sync + 'static {
    fn render(&self, output: &mut [f32], channels: usize);
    /// Port-relative monotonic microseconds from midir; 0 also denotes an
    /// immediate control-thread reset (sustain/all-notes-off on disconnect).
    fn midi(&self, slot: usize, timestamp_us: u64, data: &[u8]);
    /// Interleaved input, using the same configured sample rate as output.
    /// first_frame advances over frames dropped by this host's ring, allowing
    /// the recorder to retain those gaps. It is a capture-stream frame counter,
    /// not the transport clock or hardware latency compensation. The recording
    /// layer must establish that mapping. capture runs before render, and during stop() for
    /// the last queued frames, after both audio callbacks have been suspended.
    fn capture(&self, input: &[f32], channels: usize, first_frame: u64);
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BackendInfo { pub id: String, pub is_default: bool }

#[derive(Clone, Copy, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Direction { Input, Output }

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FormatCapability {
    pub channels: u16,
    pub sample_format: String,
    pub min_sample_rate: u32,
    pub max_sample_rate: u32,
    pub min_buffer_frames: Option<u32>,
    pub max_buffer_frames: Option<u32>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceInfo {
    pub id: String,
    pub name: String,
    pub direction: Direction,
    pub is_default: bool,
    pub formats: Vec<FormatCapability>,
    pub default_sample_rate: Option<u32>,
    pub default_channels: Option<u16>,
    /// Keep partially initialized USB devices visible and expose the query error.
    pub capability_error: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenedAudioConfig {
    pub backend: String,
    pub sample_rate: u32,
    pub output_channels: u16,
    pub input_channels: u16,
    pub buffer_frames: Option<u32>,
    pub output_format: String,
    pub input_format: Option<String>,
    pub output_device_id: String,
    pub input_device_id: Option<String>,
}

#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AudioStatus {
    pub output_callback_seen: bool,
    pub input_callback_seen: bool,
    pub output_errors: u64,
    pub input_errors: u64,
    pub input_dropped_frames: u64,
    pub input_queued_frames: usize,
}

#[derive(Default)]
struct Counters {
    output_seen: AtomicBool,
    input_seen: AtomicBool,
    output_errors: AtomicU64,
    input_errors: AtomicU64,
}

pub fn backends() -> Vec<BackendInfo> {
    let default = cpal::default_host().id();
    cpal::available_hosts().into_iter().map(|id| BackendInfo {
        id: id.name().to_owned(), is_default: id == default,
    }).collect()
}

fn select_host(backend: Option<&str>) -> Result<Host, String> {
    let Some(name) = backend.filter(|name| !name.is_empty()) else { return Ok(cpal::default_host()); };
    let id = cpal::available_hosts().into_iter().find(|id| id.name().eq_ignore_ascii_case(name))
        .ok_or_else(|| format!("Backend de áudio indisponível: {name}."))?;
    cpal::host_from_id(id).map_err(|error| error.to_string())
}

fn device_name(device: &Device) -> String {
    device.description().map(|description| {
        description.extended().iter().filter(|line| !line.trim().is_empty())
            .max_by_key(|line| line.len()).filter(|line| line.len() > description.name().len())
            .cloned().unwrap_or_else(|| description.name().to_owned())
    }).unwrap_or_else(|_| "Dispositivo de áudio".into())
}

fn device_id(device: &Device) -> String {
    device.id().map(|id| id.to_string())
        .unwrap_or_else(|_| format!("name:{}", device_name(device)))
}

fn default_config(device: &Device, direction: Direction) -> Option<SupportedStreamConfig> {
    match direction { Direction::Input => device.default_input_config().ok(),
        Direction::Output => device.default_output_config().ok() }
}

fn config_ranges(device: &Device, direction: Direction)
    -> Result<Vec<cpal::SupportedStreamConfigRange>, String>
{
    match direction {
        Direction::Input => device.supported_input_configs().map(|it| it.collect()),
        Direction::Output => device.supported_output_configs().map(|it| it.collect()),
    }.map_err(|error| error.to_string())
}

pub fn devices(backend: Option<&str>, direction: Direction) -> Result<Vec<DeviceInfo>, String> {
    let host = select_host(backend)?;
    let default = match direction { Direction::Input => host.default_input_device(),
        Direction::Output => host.default_output_device() }.map(|device| device_id(&device));
    let devices = match direction { Direction::Input => host.input_devices(),
        Direction::Output => host.output_devices() }.map_err(|error| error.to_string())?;
    Ok(devices.map(|device| {
        let id = device_id(&device);
        let native_default = default_config(&device, direction);
        let (ranges, capability_error) = match config_ranges(&device, direction) {
            Ok(ranges) => (ranges, None), Err(error) => (Vec::new(), Some(error)),
        };
        let mut formats: Vec<_> = ranges.into_iter().filter(|range| {
            (1..=MAX_CHANNELS).contains(&range.channels()) && audio_config::supported_format(range.sample_format())
                && range.max_sample_rate() >= audio_config::MIN_SAMPLE_RATE
                && range.min_sample_rate() <= audio_config::MAX_SAMPLE_RATE
        }).map(|range| {
            let (min_buffer_frames, max_buffer_frames) = buffer_range(*range.buffer_size());
            FormatCapability { channels: range.channels(), sample_format: range.sample_format().to_string(),
                min_sample_rate: range.min_sample_rate().max(audio_config::MIN_SAMPLE_RATE),
                max_sample_rate: range.max_sample_rate().min(audio_config::MAX_SAMPLE_RATE),
                min_buffer_frames, max_buffer_frames }
        }).collect();
        if formats.is_empty() {
            if let Some(config) = native_default.as_ref().filter(|config| {
                (1..=MAX_CHANNELS).contains(&config.channels()) && audio_config::supported_format(config.sample_format())
                    && (audio_config::MIN_SAMPLE_RATE..=audio_config::MAX_SAMPLE_RATE).contains(&config.sample_rate())
            }) {
                let (min_buffer_frames, max_buffer_frames) = buffer_range(*config.buffer_size());
                formats.push(FormatCapability { channels: config.channels(), sample_format: config.sample_format().to_string(),
                    min_sample_rate: config.sample_rate(), max_sample_rate: config.sample_rate(), min_buffer_frames, max_buffer_frames });
            }
        }
        DeviceInfo { is_default: default.as_ref() == Some(&id), id, name: device_name(&device), direction, formats,
            default_sample_rate: native_default.as_ref().map(|config| config.sample_rate()),
            default_channels: native_default.as_ref().map(|config| config.channels()), capability_error }
    }).collect())
}

fn buffer_range(size: SupportedBufferSize) -> (Option<u32>, Option<u32>) {
    match size { SupportedBufferSize::Range { min, max } => (Some(min), Some(max)),
        SupportedBufferSize::Unknown => (None, None) }
}

fn selected_device(host: &Host, endpoint: &EndpointConfig, direction: Direction) -> Result<Device, String> {
    if let Some(id) = endpoint.device_id.as_deref().filter(|id| !id.is_empty()) {
        let devices = match direction { Direction::Input => host.input_devices(),
            Direction::Output => host.output_devices() }.map_err(|error| error.to_string())?;
        let mut matches = devices.into_iter().filter(|device| device_id(device) == id);
        let selected = matches.next().ok_or_else(|| "O dispositivo de áudio selecionado não está mais conectado.".to_string())?;
        if matches.next().is_some() {
            return Err("O driver retornou identificadores de áudio duplicados; escolha outro dispositivo ou o padrão do sistema.".into());
        }
        return Ok(selected);
    }
    match direction { Direction::Input => host.default_input_device(),
        Direction::Output => host.default_output_device() }
        .ok_or_else(|| "Nenhum dispositivo de áudio padrão disponível.".into())
}

fn selected_config(device: &Device, endpoint: &EndpointConfig, direction: Direction,
    settings: &AudioConfig) -> Result<SupportedStreamConfig, String>
{
    // A valid default still works when a newly connected USB endpoint cannot
    // enumerate all capabilities yet. No fallback changes the requested clock.
    audio_config::select_config(default_config(device, direction),
        config_ranges(device, direction).unwrap_or_default(), endpoint.channels,
        settings.sample_rate, settings.buffer_frames)
        .ok_or_else(|| format!("{} não oferece {} canais, {} Hz e o buffer escolhido.",
            device_name(device), endpoint.channels, settings.sample_rate))
}

pub struct AudioHost {
    output: Stream,
    input: Option<Stream>,
    output_gate: Arc<CallbackGate>,
    input_gate: Arc<CallbackGate>,
    engine: Arc<dyn RealtimeEngine>,
    input_ring: Option<Arc<InputRing>>,
    stop_scratch: Vec<f32>,
    counters: Arc<Counters>,
    running: bool,
    pub config: OpenedAudioConfig,
}

impl AudioHost {
    /// Builds stopped streams. Prepare the engine for config.sample_rate and
    /// MAX_RENDER_FRAMES before start(). Only one host may render the same engine.
    pub fn open(settings: AudioConfig, engine: Arc<dyn RealtimeEngine>) -> Result<Self, String> {
        settings.validate()?;
        let host = select_host(settings.backend.as_deref())?;
        let output_device = selected_device(&host, &settings.output, Direction::Output)?;
        let selected_output = selected_config(&output_device, &settings.output, Direction::Output, &settings)?;
        let input = settings.input.as_ref().map(|endpoint| {
            let device = selected_device(&host, endpoint, Direction::Input)?;
            let config = selected_config(&device, endpoint, Direction::Input, &settings)?;
            Ok::<_, String>((device, config))
        }).transpose()?;
        let input_channels = input.as_ref().map_or(0, |(_, config)| config.channels());
        // At least 4 maximum callbacks; bounded memory even at 32 channels.
        let input_ring = (input_channels > 0).then(|| Arc::new(InputRing::new(input_channels as usize, MAX_RENDER_FRAMES * 4)));
        let counters = Arc::new(Counters::default());
        let output_gate = Arc::new(CallbackGate::suspended());
        let input_gate = Arc::new(CallbackGate::suspended());
        let mut output_config: StreamConfig = selected_output.clone().into();
        output_config.buffer_size = audio_config::selected_buffer(settings.buffer_frames, *selected_output.buffer_size())?;
        let output = build_output(&output_device, &output_config, selected_output.sample_format(), Arc::clone(&engine),
            Arc::clone(&output_gate), input_ring.clone(), Arc::clone(&counters)).map_err(|error| error.to_string())?;
        let input_stream = input.as_ref().map(|(device, selected)| {
            let mut config: StreamConfig = selected.clone().into();
            config.buffer_size = audio_config::selected_buffer(settings.buffer_frames, *selected.buffer_size())?;
            build_input(device, &config, selected.sample_format(), Arc::clone(&input_gate),
                Arc::clone(input_ring.as_ref().expect("input ring exists")), Arc::clone(&counters))
                .map_err(|error| error.to_string())
        }).transpose()?;
        let config = OpenedAudioConfig { backend: host.id().name().to_owned(), sample_rate: settings.sample_rate,
            output_channels: selected_output.channels(), input_channels, buffer_frames: settings.buffer_frames,
            output_format: selected_output.sample_format().to_string(), input_format: input.as_ref().map(|(_, c)| c.sample_format().to_string()),
            output_device_id: device_id(&output_device), input_device_id: input.as_ref().map(|(d, _)| device_id(d)) };
        Ok(Self { output, input: input_stream, output_gate, input_gate, engine, input_ring,
            stop_scratch: vec![0.0; MAX_RENDER_FRAMES * input_channels as usize], counters, running: false, config })
    }

    pub fn start(&mut self) -> Result<(), String> {
        if self.running { return Ok(()); }
        if !self.output_gate.is_quiescent() || !self.input_gate.is_quiescent() {
            return Err("Aguarde o encerramento dos callbacks de áudio anteriores.".into());
        }
        self.input_gate.resume();
        self.output_gate.resume();
        self.running = true;
        let result = self.input.as_ref().map_or(Ok(()), |input| input.play()).and_then(|_| self.output.play());
        if let Err(error) = result { let _ = self.stop(); return Err(error.to_string()); }
        Ok(())
    }

    /// Stop must succeed before reconfiguring or reusing the engine in another host.
    pub fn stop(&mut self) -> Result<(), String> {
        if !self.input_gate.suspend_and_wait() {
            return Err("O callback de entrada ainda não terminou; o motor continua reservado.".into());
        }
        let input_error = self.input.as_ref().and_then(|input| input.pause().err());
        if !self.output_gate.suspend_and_wait() {
            return Err("O callback de saída ainda não terminou; o motor continua reservado.".into());
        }
        let output_error = self.output.pause().err();
        self.running = false;
        // Preserve the captured tail for recording. Both stream gates are now
        // quiescent, so this is the only consumer and cannot race render/capture.
        if let Some(ring) = self.input_ring.as_ref() {
            while let Some((samples, first_frame)) = ring.read(&mut self.stop_scratch) {
                self.engine.capture(&self.stop_scratch[..samples], ring.channels, first_frame);
            }
        }
        if let Some(error) = input_error.or(output_error) { return Err(error.to_string()); }
        Ok(())
    }

    pub fn status(&self) -> AudioStatus {
        AudioStatus { output_callback_seen: self.counters.output_seen.load(Ordering::Acquire),
            input_callback_seen: self.counters.input_seen.load(Ordering::Acquire),
            output_errors: self.counters.output_errors.load(Ordering::Relaxed),
            input_errors: self.counters.input_errors.load(Ordering::Relaxed),
            input_dropped_frames: self.input_ring.as_ref().map_or(0, |ring| ring.dropped.load(Ordering::Relaxed)),
            input_queued_frames: self.input_ring.as_ref().map_or(0, |ring| ring.queued()) }
    }
}

impl Drop for AudioHost {
    fn drop(&mut self) {
        // On a timeout gates remain closed. Callback-owned Arcs retain the engine
        // until CPAL releases the stream, even if the control owner is dropped.
        let _ = self.stop();
    }
}

// One input producer, one output consumer. Atomic sample storage avoids unsafe
// shared memory; release/acquire indices publish complete interleaved frames.
// Sequence numbers retain capture gaps if a full ring drops incoming frames.
struct InputRing {
    channels: usize,
    capacity_frames: usize,
    samples: Box<[AtomicU32]>,
    sequence: Box<[AtomicU64]>,
    write: AtomicUsize,
    read: AtomicUsize,
    dropped: AtomicU64,
}

impl InputRing {
    fn new(channels: usize, capacity_frames: usize) -> Self {
        assert!((1..=MAX_CHANNELS as usize).contains(&channels));
        assert!(capacity_frames > 0);
        Self { channels, capacity_frames,
            samples: (0..capacity_frames * channels).map(|_| AtomicU32::new(0)).collect(),
            sequence: (0..capacity_frames).map(|_| AtomicU64::new(0)).collect(),
            write: AtomicUsize::new(0), read: AtomicUsize::new(0), dropped: AtomicU64::new(0) }
    }

    fn push<T: Sample>(&self, input: &[T], first_frame: u64) where f32: FromSample<T> {
        let write = self.write.load(Ordering::Relaxed);
        let read = self.read.load(Ordering::Acquire);
        let incoming = input.len() / self.channels;
        let accepted = incoming.min(self.capacity_frames.saturating_sub(write.wrapping_sub(read)));
        for frame in 0..accepted {
            let index = write.wrapping_add(frame) % self.capacity_frames;
            for channel in 0..self.channels {
                let sample = f32::from_sample(input[frame * self.channels + channel]);
                self.samples[index * self.channels + channel].store(finite(sample).to_bits(), Ordering::Relaxed);
            }
            self.sequence[index].store(first_frame.wrapping_add(frame as u64), Ordering::Relaxed);
        }
        self.write.store(write.wrapping_add(accepted), Ordering::Release);
        self.dropped.fetch_add((incoming - accepted) as u64, Ordering::Relaxed);
    }

    fn read(&self, output: &mut [f32]) -> Option<(usize, u64)> {
        let read = self.read.load(Ordering::Relaxed);
        let write = self.write.load(Ordering::Acquire);
        let count = write.wrapping_sub(read).min(output.len() / self.channels);
        if count == 0 { return None; }
        let first = self.sequence[read % self.capacity_frames].load(Ordering::Relaxed);
        let mut frames = 0;
        for frame in 0..count {
            let index = read.wrapping_add(frame) % self.capacity_frames;
            if self.sequence[index].load(Ordering::Relaxed) != first.wrapping_add(frame as u64) { break; }
            for channel in 0..self.channels {
                output[frame * self.channels + channel] = f32::from_bits(self.samples[index * self.channels + channel].load(Ordering::Relaxed));
            }
            frames += 1;
        }
        self.read.store(read.wrapping_add(frames), Ordering::Release);
        Some((frames * self.channels, first))
    }

    fn queued(&self) -> usize {
        let read = self.read.load(Ordering::Acquire);
        self.write.load(Ordering::Acquire).wrapping_sub(read).min(self.capacity_frames)
    }
}

fn finite(value: f32) -> f32 { if value.is_finite() { value } else { 0.0 } }

struct OutputCallback {
    channels: usize,
    engine: Arc<dyn RealtimeEngine>,
    gate: Arc<CallbackGate>,
    ring: Option<Arc<InputRing>>,
    counters: Arc<Counters>,
    scratch: Box<[f32]>,
    capture: Box<[f32]>,
}

impl OutputCallback {
    fn new(channels: usize, engine: Arc<dyn RealtimeEngine>, gate: Arc<CallbackGate>,
        ring: Option<Arc<InputRing>>, counters: Arc<Counters>) -> Self
    {
        let scratch = vec![0.0; MAX_RENDER_FRAMES * channels].into_boxed_slice();
        let capture = vec![0.0; MAX_RENDER_FRAMES * ring.as_ref().map_or(0, |ring| ring.channels)].into_boxed_slice();
        Self { channels, engine, gate, ring, counters, scratch, capture }
    }

    fn process<T: SizedSample + FromSample<f32>>(&mut self, output: &mut [T]) {
        let Some(_active) = self.gate.enter() else { output.fill(T::EQUILIBRIUM); return; };
        self.counters.output_seen.store(true, Ordering::Release);
        let valid_samples = output.len() / self.channels * self.channels;
        for chunk in output[..valid_samples].chunks_mut(MAX_RENDER_FRAMES * self.channels) {
            if let Some(ring) = self.ring.as_ref() {
                // Drain at most one bounded capture block per render block. Clock
                // drift between unrelated devices is measured as overrun/gaps;
                // there is deliberately no hidden rate change or resampling.
                if let Some((samples, frame)) = ring.read(&mut self.capture) {
                    self.engine.capture(&self.capture[..samples], ring.channels, frame);
                }
            }
            let scratch = &mut self.scratch[..chunk.len()];
            scratch.fill(0.0);
            self.engine.render(scratch, self.channels);
            for (target, source) in chunk.iter_mut().zip(scratch.iter()) {
                *target = T::from_sample(finite(*source).clamp(-1.0, 1.0));
            }
        }
        output[valid_samples..].fill(T::EQUILIBRIUM);
    }
}

fn output_stream<T>(device: &Device, config: &StreamConfig, engine: Arc<dyn RealtimeEngine>,
    gate: Arc<CallbackGate>, ring: Option<Arc<InputRing>>, counters: Arc<Counters>)
    -> Result<Stream, cpal::BuildStreamError>
where T: SizedSample + FromSample<f32> {
    let errors = Arc::clone(&counters);
    let mut callback = OutputCallback::new(config.channels as usize, engine, gate, ring, counters);
    device.build_output_stream(config, move |output: &mut [T], _| callback.process(output),
        move |_| { errors.output_errors.fetch_add(1, Ordering::Relaxed); }, None)
}

fn input_stream<T>(device: &Device, config: &StreamConfig, gate: Arc<CallbackGate>,
    ring: Arc<InputRing>, counters: Arc<Counters>) -> Result<Stream, cpal::BuildStreamError>
where T: SizedSample, f32: FromSample<T> {
    let errors = Arc::clone(&counters);
    let mut frame = 0_u64;
    device.build_input_stream(config, move |input: &[T], _| {
        let Some(_active) = gate.enter() else { return; };
        counters.input_seen.store(true, Ordering::Release);
        ring.push(input, frame);
        frame = frame.wrapping_add((input.len() / ring.channels) as u64);
    }, move |_| { errors.input_errors.fetch_add(1, Ordering::Relaxed); }, None)
}

macro_rules! sample_dispatch {
    ($format:expr, $function:ident, $($argument:expr),+ $(,)?) => {
        match $format {
            SampleFormat::F32 => $function::<f32>($($argument),+),
            SampleFormat::F64 => $function::<f64>($($argument),+),
            SampleFormat::I8 => $function::<i8>($($argument),+),
            SampleFormat::I16 => $function::<i16>($($argument),+),
            SampleFormat::I24 => $function::<cpal::I24>($($argument),+),
            SampleFormat::I32 => $function::<i32>($($argument),+),
            SampleFormat::I64 => $function::<i64>($($argument),+),
            SampleFormat::U8 => $function::<u8>($($argument),+),
            SampleFormat::U16 => $function::<u16>($($argument),+),
            SampleFormat::U24 => $function::<cpal::U24>($($argument),+),
            SampleFormat::U32 => $function::<u32>($($argument),+),
            SampleFormat::U64 => $function::<u64>($($argument),+),
            _ => Err(cpal::BuildStreamError::StreamConfigNotSupported),
        }
    };
}

fn build_output(device: &Device, config: &StreamConfig, format: SampleFormat,
    engine: Arc<dyn RealtimeEngine>, gate: Arc<CallbackGate>, ring: Option<Arc<InputRing>>, counters: Arc<Counters>)
    -> Result<Stream, cpal::BuildStreamError>
{
    sample_dispatch!(format, output_stream, device, config, engine, gate, ring, counters)
}

fn build_input(device: &Device, config: &StreamConfig, format: SampleFormat,
    gate: Arc<CallbackGate>, ring: Arc<InputRing>, counters: Arc<Counters>) -> Result<Stream, cpal::BuildStreamError>
{
    sample_dispatch!(format, input_stream, device, config, gate, ring, counters)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn multichannel_ring_preserves_frames_across_wrap_and_reports_overflow_gaps() {
        let ring = InputRing::new(2, 3);
        ring.push(&[0.1_f32, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8], 0);
        assert_eq!(ring.dropped.load(Ordering::Relaxed), 1);
        let mut output = [0.0; 4];
        assert_eq!(ring.read(&mut output), Some((4, 0)));
        assert_eq!(output, [0.1, 0.2, 0.3, 0.4]);
        ring.push(&[0.9_f32, 1.0, 0.2, 0.3], 4);
        assert_eq!(ring.read(&mut output), Some((2, 2)));
        assert_eq!(&output[..2], &[0.5, 0.6]);
        assert_eq!(ring.read(&mut output), Some((4, 4)));
        assert_eq!(output, [0.9, 1.0, 0.2, 0.3]);
        assert!(ring.read(&mut output).is_none());
    }

    #[test]
    fn input_integer_zero_and_extremes_are_converted_correctly() {
        let ring = InputRing::new(1, 3);
        ring.push(&[0_u16, 32768, u16::MAX], 0);
        let mut output = [0.0; 3];
        assert_eq!(ring.read(&mut output), Some((3, 0)));
        assert_eq!(output[0], -1.0);
        assert_eq!(output[1], 0.0);
        assert!((output[2] - 1.0).abs() < 0.0001);
    }

    #[test]
    fn ring_producer_and_consumer_keep_channel_alignment_under_contention() {
        let ring = Arc::new(InputRing::new(2, 64));
        std::thread::scope(|scope| {
            let producer = Arc::clone(&ring);
            scope.spawn(move || {
                for frame in 0..10_000_u64 {
                    while producer.queued() == producer.capacity_frames { std::thread::yield_now(); }
                    producer.push(&[frame as f32, -(frame as f32)], frame);
                }
            });
            let mut expected = 0;
            let mut output = [0.0; 26];
            while expected < 10_000 {
                if let Some((samples, first)) = ring.read(&mut output) {
                    assert_eq!(first, expected);
                    for pair in output[..samples].chunks_exact(2) {
                        assert_eq!(pair, &[expected as f32, -(expected as f32)]);
                        expected += 1;
                    }
                } else { std::thread::yield_now(); }
            }
        });
        assert_eq!(ring.dropped.load(Ordering::Relaxed), 0);
    }

    #[derive(Default)]
    struct CountingEngine { rendered: AtomicUsize, callbacks: AtomicUsize, captured: AtomicUsize }
    impl RealtimeEngine for CountingEngine {
        fn render(&self, output: &mut [f32], channels: usize) {
            assert_eq!(output.len() % channels, 0);
            assert!(output.len() / channels <= MAX_RENDER_FRAMES);
            self.rendered.fetch_add(output.len() / channels, Ordering::Relaxed);
            self.callbacks.fetch_add(1, Ordering::Relaxed);
            output.fill(0.5);
        }
        fn midi(&self, _: usize, _: u64, _: &[u8]) {}
        fn capture(&self, input: &[f32], channels: usize, _: u64) {
            self.captured.fetch_add(input.len() / channels, Ordering::Relaxed);
        }
    }

    #[test]
    fn larger_driver_callbacks_are_split_without_resizing_or_losing_frames() {
        let engine = Arc::new(CountingEngine::default());
        let mut callback = OutputCallback::new(32, engine.clone(), Arc::new(CallbackGate::default()),
            None, Arc::new(Counters::default()));
        let scratch_pointer = callback.scratch.as_ptr();
        let mut output = vec![0.0_f32; (MAX_RENDER_FRAMES + 257) * 32];
        callback.process(&mut output);
        assert_eq!(engine.rendered.load(Ordering::Relaxed), MAX_RENDER_FRAMES + 257);
        assert_eq!(engine.callbacks.load(Ordering::Relaxed), 2);
        assert!(output.iter().all(|sample| *sample == 0.5));
        assert_eq!(callback.scratch.as_ptr(), scratch_pointer);
    }

    #[test]
    fn suspended_callback_silences_unsigned_output_without_advancing_engine() {
        let engine = Arc::new(CountingEngine::default());
        let mut callback = OutputCallback::new(2, engine.clone(), Arc::new(CallbackGate::suspended()),
            None, Arc::new(Counters::default()));
        let mut output = [0_u16; 16];
        callback.process(&mut output);
        assert_eq!(output, [32768; 16]);
        assert_eq!(engine.rendered.load(Ordering::Relaxed), 0);
    }
}
