//! Exclusive control-thread owner of the shared C++ document/transport model.
//! This object never enters an audio callback. Rust and C++ own and free their
//! respective allocations, including all error paths.
use serde_json::{json, Value};
use std::ffi::{c_char, c_void, CStr};
use std::ptr::NonNull;

extern "C" {
    fn catlive_document_create() -> *mut c_void;
    fn catlive_document_destroy(document: *mut c_void);
    fn catlive_document_request(document: *mut c_void, request: *const c_char, length: usize) -> *mut c_char;
    fn catlive_document_free_response(response: *mut c_char);
}

struct Response(NonNull<c_char>);
impl Drop for Response {
    fn drop(&mut self) { unsafe { catlive_document_free_response(self.0.as_ptr()) } }
}
pub struct Document { handle: NonNull<c_void> }
// The native handle has no thread-affine resources and can move between control
// threads. Its request method requires &mut self; it is deliberately not Sync.
unsafe impl Send for Document {}
impl Document {
    pub fn new() -> Result<Self, String> {
        NonNull::new(unsafe { catlive_document_create() })
            .map(|handle| Self { handle }).ok_or_else(|| "Sem memória para abrir o projeto.".into())
    }
    pub fn request(&mut self, request: &Value) -> Result<Value, String> {
        let bytes = serde_json::to_vec(request).map_err(|e| e.to_string())?;
        let pointer = unsafe { catlive_document_request(self.handle.as_ptr(), bytes.as_ptr().cast(), bytes.len()) };
        let response = Response(NonNull::new(pointer).ok_or("Sem memória para processar o projeto.")?);
        let text = unsafe { CStr::from_ptr(response.0.as_ptr()) }.to_bytes();
        let mut result: Value = serde_json::from_slice(text).map_err(|e| e.to_string())?;
        if result["ok"] == true { Ok(result["data"].take()) }
        else { Err(result["error"].as_str().unwrap_or("Falha ao processar o projeto.").into()) }
    }
    pub fn open(&mut self, path: &str) -> Result<Value, String> { self.request(&json!({"operation":"open","path":path})) }
    pub fn save(&mut self, path: &str) -> Result<Value, String> { self.request(&json!({"operation":"save","path":path})) }
    pub fn state(&mut self) -> Result<Value, String> { self.request(&json!({"operation":"state"})) }
    pub fn document(&mut self) -> Result<Value, String> { self.request(&json!({"operation":"document"})) }
    pub fn action(&mut self, action: Value) -> Result<Value, String> { self.request(&json!({"operation":"action","request":action})) }
}
impl Drop for Document {
    fn drop(&mut self) { unsafe { catlive_document_destroy(self.handle.as_ptr()) } }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn errors_cross_ffi_without_losing_document() {
        let mut document = Document::new().unwrap();
        let before = document.state().unwrap();
        assert!(document.request(&json!({"operation":"invalid"})).is_err());
        assert!(document.open("\0invalid").is_err());
        assert!(document.request(&json!({"operation":"load","document":null})).is_err());
        assert_eq!(document.state().unwrap(), before);
    }
    #[test]
    fn native_handle_moves_safely_between_control_threads() {
        let mut document = Document::new().unwrap();
        let state = std::thread::spawn(move || document.state().unwrap()).join().unwrap();
        assert_eq!(state["dirty"], false);
    }
}
