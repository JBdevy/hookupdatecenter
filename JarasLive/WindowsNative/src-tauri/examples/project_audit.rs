use catlive_native_host::document::Document;
use serde_json::json;
fn main() -> Result<(), String> {
    let path = std::env::args().nth(1).ok_or("Informe o projeto a verificar.")?;
    let mut session = Document::new()?;
    let state = session.open(&path)?;
    let document = session.document()?;
    let songs = document["songs"].as_array().ok_or("Projeto sem músicas.")?;
    let mut track_count = 0;
    let mut item_count = 0;
    for song in songs {
        if let Some(tracks) = song["tracks"].as_array() {
            track_count += tracks.len();
            for track in tracks { item_count += track["clips"].as_array().map_or(0, Vec::len); }
        }
    }
    println!("{}", json!({"opened":true,"dirty":state["dirty"],"songs":songs.len(),
        "tracks":track_count,"items":item_count,"transport":state["transport"]}));
    Ok(())
}
