use cpal::{BufferSize, SampleFormat, SupportedBufferSize, SupportedStreamConfig,
    SupportedStreamConfigRange};
use serde::{Deserialize, Serialize};

pub const MIN_SAMPLE_RATE: u32 = 8_000;
pub const MAX_SAMPLE_RATE: u32 = 384_000;
pub const MAX_CHANNELS: u16 = 32;
pub const MAX_RENDER_FRAMES: usize = 8192;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EndpointConfig {
    /// None selects the system default on the requested backend.
    pub device_id: Option<String>,
    pub channels: u16,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AudioConfig {
    /// CPAL HostId::name(), e.g. WASAPI or ASIO. None selects default_host().
    pub backend: Option<String>,
    pub output: EndpointConfig,
    pub input: Option<EndpointConfig>,
    pub sample_rate: u32,
    /// None uses the driver's default. Explicit requests never silently change.
    pub buffer_frames: Option<u32>,
}

impl Default for AudioConfig {
    fn default() -> Self {
        Self { backend: None, output: EndpointConfig { device_id: None, channels: 2 },
            input: None, sample_rate: 48_000, buffer_frames: None }
    }
}

impl AudioConfig {
    pub fn validate(&self) -> Result<(), String> {
        if !(MIN_SAMPLE_RATE..=MAX_SAMPLE_RATE).contains(&self.sample_rate) {
            return Err("Taxa de amostragem fora do intervalo de 8.000 a 384.000 Hz.".into());
        }
        for endpoint in std::iter::once(&self.output).chain(self.input.iter()) {
            if !(1..=MAX_CHANNELS).contains(&endpoint.channels) {
                return Err("Escolha entre 1 e 32 canais por dispositivo.".into());
            }
        }
        if self.buffer_frames == Some(0) {
            return Err("O buffer de áudio deve ter pelo menos um frame.".into());
        }
        Ok(())
    }
}

pub fn supported_format(format: SampleFormat) -> bool {
    matches!(format, SampleFormat::F32 | SampleFormat::F64 | SampleFormat::I8 |
        SampleFormat::I16 | SampleFormat::I24 | SampleFormat::I32 | SampleFormat::I64 |
        SampleFormat::U8 | SampleFormat::U16 | SampleFormat::U24 | SampleFormat::U32 |
        SampleFormat::U64)
}

fn format_rank(format: SampleFormat) -> u8 {
    match format { SampleFormat::F32 => 0, SampleFormat::F64 => 1,
        SampleFormat::I32 => 2, SampleFormat::I24 => 3, SampleFormat::I16 => 4, _ => 5 }
}

pub fn selected_buffer(requested: Option<u32>, supported: SupportedBufferSize)
    -> Result<BufferSize, String>
{
    match requested {
        None => Ok(BufferSize::Default),
        Some(0) => Err("O buffer de áudio deve ter pelo menos um frame.".into()),
        Some(frames) => {
            if let SupportedBufferSize::Range { min, max } = supported {
                if frames < min || frames > max {
                    return Err(format!("O dispositivo aceita buffers de {min} a {max} frames."));
                }
            }
            // Unknown means the backend did not advertise a range. Try the exact
            // request; a backend rejection is returned, never hidden by fallback.
            Ok(BufferSize::Fixed(frames))
        }
    }
}

/// Unlike Bronze Keys' instrument-specific rate policy, CatLive preserves any
/// explicitly selected supported rate, channel count and buffer size.
pub fn select_config(
    default: Option<SupportedStreamConfig>,
    ranges: impl IntoIterator<Item = SupportedStreamConfigRange>,
    channels: u16,
    requested_rate: u32,
    requested_buffer: Option<u32>,
) -> Option<SupportedStreamConfig> {
    if !(1..=MAX_CHANNELS).contains(&channels)
        || !(MIN_SAMPLE_RATE..=MAX_SAMPLE_RATE).contains(&requested_rate) { return None; }
    let usable = |config: &SupportedStreamConfig| config.channels() == channels
        && config.sample_rate() == requested_rate && supported_format(config.sample_format())
        && selected_buffer(requested_buffer, *config.buffer_size()).is_ok();
    let preferred = default.filter(usable);
    let selected = ranges.into_iter().filter_map(|range| {
        if range.channels() != channels || !supported_format(range.sample_format())
            || requested_rate < range.min_sample_rate() || requested_rate > range.max_sample_rate()
            || selected_buffer(requested_buffer, *range.buffer_size()).is_err() { return None; }
        Some(range.with_sample_rate(requested_rate))
    }).chain(preferred).min_by_key(|config| format_rank(config.sample_format()));
    selected
}

#[cfg(test)]
mod tests {
    use super::*;

    fn range(channels: u16, min: u32, max: u32) -> SupportedStreamConfigRange {
        SupportedStreamConfigRange::new(channels, min, max,
            SupportedBufferSize::Range { min: 64, max: 2048 }, SampleFormat::F32)
    }

    #[test]
    fn rates_and_multichannel_are_not_clamped_to_bronze_keyboard_defaults() {
        for rate in [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 384_000] {
            let chosen = select_config(None, [range(32, 8_000, 384_000)], 32, rate, Some(1024)).unwrap();
            assert_eq!((chosen.channels(), chosen.sample_rate()), (32, rate));
        }
    }

    #[test]
    fn unsupported_rate_layout_and_buffer_are_rejected_instead_of_substituted() {
        assert!(select_config(None, [range(2, 48_000, 48_000)], 2, 44_100, None).is_none());
        assert!(select_config(None, [range(2, 48_000, 48_000)], 8, 48_000, None).is_none());
        assert!(select_config(None, [range(2, 48_000, 48_000)], 2, 48_000, Some(32)).is_none());
        assert!(select_config(None, [range(2, 8_000, 1_536_000)], 2, 1_536_000, None).is_none());
    }

    #[test]
    fn unknown_buffer_range_keeps_explicit_request() {
        assert_eq!(selected_buffer(Some(4096), SupportedBufferSize::Unknown).unwrap(), BufferSize::Fixed(4096));
        assert!(selected_buffer(Some(0), SupportedBufferSize::Unknown).is_err());
    }
}
