//! Short, silent device lifecycle probe. Does not change saved device settings,
//! read microphone data or open a CatLive project/window.
use catlive_native_host::{audio::{self, AudioHost, Direction, RealtimeEngine}, audio_config::{AudioConfig, EndpointConfig}};
use std::sync::{Arc, atomic::{AtomicU64, Ordering}};
use std::time::Duration;
use serde_json::json;
#[derive(Default)]
struct Silence { frames: AtomicU64 }
impl RealtimeEngine for Silence {
    fn render(&self, output: &mut [f32], channels: usize) {
        output.fill(0.0);
        self.frames.fetch_add((output.len()/channels) as u64, Ordering::Relaxed);
    }
    fn midi(&self, _: usize, _: u64, _: &[u8]) {}
    fn capture(&self, _: &[f32], _: usize, _: u64) {}
}
fn main() -> Result<(), String> {
    let device = audio::devices(None, Direction::Output)?.into_iter()
        .find(|device| device.is_default).ok_or("Nenhuma saída padrão disponível.")?;
    let settings = AudioConfig { backend:None, input:None,
        output:EndpointConfig {device_id:Some(device.id),channels:device.default_channels.ok_or("Canais indisponíveis.")?},
        sample_rate:device.default_sample_rate.ok_or("Taxa indisponível.")?, buffer_frames:None };
    let engine = Arc::new(Silence::default());
    let mut host = AudioHost::open(settings, engine.clone())?;
    host.start()?;
    for _ in 0..20 {
        if engine.frames.load(Ordering::Relaxed) > 8192 {break;}
        std::thread::sleep(Duration::from_millis(50));
    }
    host.stop()?;
    let frames = engine.frames.load(Ordering::Relaxed);
    let status = host.status();
    if !status.output_callback_seen || frames == 0 || status.output_errors != 0 {
        return Err(format!("Falha no callback: {}",serde_json::to_string(&status).unwrap()));
    }
    std::thread::sleep(Duration::from_millis(100));
    if engine.frames.load(Ordering::Relaxed) != frames {return Err("Callback continuou após stop.".into());}
    println!("{}",json!({"passed":true,"device":device.name,"frames":frames,"config":host.config,"status":status}));
    Ok(())
}
