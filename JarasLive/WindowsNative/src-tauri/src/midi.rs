//! MIDI transport using the OS ports exposed by midir. Device I/O and selection
//! are independent of Tauri; input callbacks only forward bytes to the engine.
use crate::audio::RealtimeEngine;
use crate::audio_callback_gate::CallbackGate;
use midir::{Ignore, MidiInput, MidiInputConnection, MidiOutput, MidiOutputConnection};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

pub const MAX_MIDI_SLOTS: usize = 32;

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MidiPortInfo { pub id: String, pub name: String }

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MidiSelection { pub slot: usize, pub device_id: String }

pub fn input_ports() -> Result<Vec<MidiPortInfo>, String> {
    let input = MidiInput::new("CatLive MIDI enumeration").map_err(|error| error.to_string())?;
    Ok(input.ports().iter().map(|port| MidiPortInfo {
        id: port.id(), name: input.port_name(port).unwrap_or_else(|_| "Entrada MIDI".into()),
    }).collect())
}

pub fn output_ports() -> Result<Vec<MidiPortInfo>, String> {
    let output = MidiOutput::new("CatLive MIDI enumeration").map_err(|error| error.to_string())?;
    Ok(output.ports().iter().map(|port| MidiPortInfo {
        id: port.id(), name: output.port_name(port).unwrap_or_else(|_| "Saída MIDI".into()),
    }).collect())
}

fn validate_selections(selections: &[MidiSelection]) -> Result<(), String> {
    let mut slots = HashSet::new();
    let mut devices = HashSet::new();
    for selection in selections {
        if selection.slot >= MAX_MIDI_SLOTS || selection.device_id.is_empty() {
            return Err("Seleção de porta MIDI inválida.".into());
        }
        if !slots.insert(selection.slot) {
            return Err("O mesmo slot MIDI não pode usar duas portas.".into());
        }
        // Route one input to several tracks in the engine, without opening the
        // hardware repeatedly and duplicating every clock/note/SysEx message.
        if !devices.insert(&selection.device_id) {
            return Err("A mesma porta MIDI não pode ocupar dois slots.".into());
        }
    }
    Ok(())
}

struct InputConnection {
    selection: MidiSelection,
    slot: Arc<AtomicUsize>,
    gate: Arc<CallbackGate>,
    _connection: MidiInputConnection<()>,
}

struct OutputConnection {
    selection: MidiSelection,
    connection: MidiOutputConnection,
}

pub struct MidiHost {
    engine: Arc<dyn RealtimeEngine>,
    inputs: Vec<InputConnection>,
    outputs: Vec<OutputConnection>,
}

impl MidiHost {
    pub fn new(engine: Arc<dyn RealtimeEngine>) -> Self {
        Self { engine, inputs: Vec::new(), outputs: Vec::new() }
    }

    /// Control thread only. Opens changed devices first while their gates are
    /// closed; existing ports remain connected when only their slot changes.
    /// Missing devices fail without removing the previous working selection.
    pub fn select_inputs(&mut self, selections: Vec<MidiSelection>) -> Result<(), String> {
        validate_selections(&selections)?;
        let mut added = Vec::new();
        for selection in &selections {
            if self.inputs.iter().any(|entry| entry.selection.device_id == selection.device_id) { continue; }
            let mut input = MidiInput::new("CatLive MIDI input").map_err(|error| error.to_string())?;
            input.ignore(Ignore::None); // Keep realtime clock, active sensing and SysEx.
            let port = input.ports().into_iter().find(|port| port.id() == selection.device_id)
                .ok_or_else(|| "A entrada MIDI selecionada não está mais conectada.".to_string())?;
            let engine = Arc::clone(&self.engine);
            let gate = Arc::new(CallbackGate::suspended());
            let callback_gate = Arc::clone(&gate);
            let slot = Arc::new(AtomicUsize::new(selection.slot));
            let callback_slot = Arc::clone(&slot);
            let connection = input.connect(&port, "CatLive", move |timestamp, data, _| {
                let Some(_active) = callback_gate.enter() else { return; };
                if data.is_empty() { return; }
                engine.midi(callback_slot.load(Ordering::Relaxed), timestamp, data);
            }, ()).map_err(|error| error.to_string())?;
            added.push(InputConnection { selection: selection.clone(), slot, gate, _connection: connection });
        }
        // The engine must no longer receive events from the old slot while its
        // routing is reassigned. No locks, allocations or UI events in callbacks.
        for entry in &self.inputs {
            if !entry.gate.suspend_and_wait() {
                // Remain suspended rather than overlap a callback with a handoff.
                return Err("O callback MIDI ainda está ocupado; tente selecionar as portas novamente.".into());
            }
        }
        for entry in &self.inputs {
            if !selections.contains(&entry.selection) {
                release_input_notes(self.engine.as_ref(), entry.selection.slot);
            }
        }
        self.inputs.retain(|entry| selections.iter().any(|selection| selection.device_id == entry.selection.device_id));
        self.inputs.extend(added);
        for selection in selections {
            if let Some(entry) = self.inputs.iter_mut().find(|entry| entry.selection.device_id == selection.device_id) {
                entry.slot.store(selection.slot, Ordering::Relaxed);
                entry.selection = selection;
                entry.gate.resume();
            }
        }
        Ok(())
    }

    /// Control/MIDI worker thread only, never an audio callback. Connections are
    /// retained across slot changes so an exclusive MIDI driver is not reopened.
    pub fn select_outputs(&mut self, selections: Vec<MidiSelection>) -> Result<(), String> {
        validate_selections(&selections)?;
        let mut added = Vec::new();
        for selection in &selections {
            if self.outputs.iter().any(|entry| entry.selection.device_id == selection.device_id) { continue; }
            let output = MidiOutput::new("CatLive MIDI output").map_err(|error| error.to_string())?;
            let port = output.ports().into_iter().find(|port| port.id() == selection.device_id)
                .ok_or_else(|| "A saída MIDI selecionada não está mais conectada.".to_string())?;
            let connection = output.connect(&port, "CatLive").map_err(|error| error.to_string())?;
            added.push(OutputConnection { selection: selection.clone(), connection });
        }
        self.outputs.retain(|entry| selections.iter().any(|selection| selection.device_id == entry.selection.device_id));
        self.outputs.extend(added);
        for selection in selections {
            if let Some(entry) = self.outputs.iter_mut().find(|entry| entry.selection.device_id == selection.device_id) {
                entry.selection = selection;
            }
        }
        Ok(())
    }

    /// midir send may enter the device driver. Call from the dedicated MIDI
    /// scheduler/control thread, never from RealtimeEngine::render/capture.
    pub fn send(&mut self, slot: usize, data: &[u8]) -> Result<(), String> {
        if data.is_empty() { return Err("Mensagem MIDI vazia.".into()); }
        let output = self.outputs.iter_mut().find(|entry| entry.selection.slot == slot)
            .ok_or_else(|| "Nenhuma saída MIDI está selecionada nesse slot.".to_string())?;
        output.connection.send(data).map_err(|error| error.to_string())
    }

    /// Release held notes before disconnecting a selected output. Called by the
    /// transport's explicit panic/stop policy, not automatically during playback.
    pub fn all_notes_off(&mut self, slot: usize) -> Result<(), String> {
        for channel in 0..16_u8 {
            self.send(slot, &[0xb0 | channel, 64, 0])?; // sustain off
            self.send(slot, &[0xb0 | channel, 123, 0])?;
        }
        Ok(())
    }

    pub fn stop_inputs(&mut self) -> Result<(), String> {
        for input in &self.inputs {
            if !input.gate.suspend_and_wait() {
                return Err("O callback MIDI ainda está ocupado; o motor continua reservado.".into());
            }
        }
        for input in &self.inputs { release_input_notes(self.engine.as_ref(), input.selection.slot); }
        self.inputs.clear();
        Ok(())
    }
}

fn release_input_notes(engine: &dyn RealtimeEngine, slot: usize) {
    // Route changes must release sustain and held notes in the old slot. Zero
    // timestamp marks a control-thread reset to apply immediately in the engine.
    for channel in 0..16_u8 {
        engine.midi(slot, 0, &[0xb0 | channel, 64, 0]);
        engine.midi(slot, 0, &[0xb0 | channel, 123, 0]);
    }
}

impl Drop for MidiHost {
    fn drop(&mut self) {
        let _ = self.stop_inputs();
        // midir retains each callback's engine Arc until that connection closes.
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn selected(slot: usize, id: &str) -> MidiSelection {
        MidiSelection { slot, device_id: id.into() }
    }

    #[test]
    fn routing_accepts_distinct_input_and_output_slots_without_index_device_ids() {
        assert!(validate_selections(&[selected(0, "usb-keyboard-stable-id"), selected(31, "din-input-id")]).is_ok());
    }

    #[test]
    fn repeated_ports_and_invalid_slots_cannot_duplicate_notes() {
        assert!(validate_selections(&[selected(0, "keyboard"), selected(1, "keyboard")]).is_err());
        assert!(validate_selections(&[selected(0, "one"), selected(0, "two")]).is_err());
        assert!(validate_selections(&[selected(32, "keyboard")]).is_err());
        assert!(validate_selections(&[selected(0, "")]).is_err());
    }
}
