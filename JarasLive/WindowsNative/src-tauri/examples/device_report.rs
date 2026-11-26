use catlive_native_host::{audio::{self, Direction}, midi};
use serde_json::json;
fn main() {
    let report = json!({
        "backends": audio::backends(),
        "outputs": audio::devices(None, Direction::Output),
        "inputs": audio::devices(None, Direction::Input),
        "midiInputs": midi::input_ports(), "midiOutputs": midi::output_ports()
    });
    println!("{}", serde_json::to_string_pretty(&report).unwrap());
}
