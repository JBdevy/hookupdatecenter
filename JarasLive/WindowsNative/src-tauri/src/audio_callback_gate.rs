use std::sync::atomic::{AtomicU8, Ordering};
use std::time::{Duration, Instant};

// Based on Bronze Keys' callback handoff. Bit 0 is the active callback;
// bit 1 forbids new entries. The audio thread never waits for the control thread.
#[derive(Default)]
pub struct CallbackGate(AtomicU8);

pub struct CallbackGuard<'a>(&'a CallbackGate);

impl CallbackGate {
    pub fn suspended() -> Self { Self(AtomicU8::new(2)) }

    pub fn enter(&self) -> Option<CallbackGuard<'_>> {
        self.0.compare_exchange(0, 1, Ordering::Acquire, Ordering::Relaxed)
            .ok().map(|_| CallbackGuard(self))
    }

    /// Control thread only. A failed wait leaves entry forbidden: the caller
    /// must not reuse the engine until a subsequent wait succeeds.
    pub fn suspend_and_wait(&self) -> bool {
        self.suspend_and_wait_for(Duration::from_millis(500))
    }

    pub fn suspend_and_wait_for(&self, timeout: Duration) -> bool {
        self.0.fetch_or(2, Ordering::AcqRel);
        let deadline = Instant::now() + timeout;
        while !self.is_quiescent() {
            if Instant::now() >= deadline { return false; }
            std::thread::sleep(Duration::from_millis(1));
        }
        true
    }

    pub fn is_quiescent(&self) -> bool { self.0.load(Ordering::Acquire) == 2 }

    /// Control thread only, after a successful suspend/wait.
    pub fn resume(&self) -> bool {
        self.0.compare_exchange(2, 0, Ordering::AcqRel, Ordering::Acquire).is_ok()
    }
}

impl Drop for CallbackGuard<'_> {
    fn drop(&mut self) { self.0.0.fetch_sub(1, Ordering::Release); }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn handoff_waits_for_callback_and_blocks_new_entries() {
        let gate = CallbackGate::default();
        let active = gate.enter().unwrap();
        assert!(gate.enter().is_none());
        std::thread::scope(|scope| {
            let waiting = scope.spawn(|| gate.suspend_and_wait());
            while gate.0.load(Ordering::Acquire) != 3 { std::thread::yield_now(); }
            assert!(gate.enter().is_none());
            drop(active);
            assert!(waiting.join().unwrap());
        });
        assert!(gate.enter().is_none());
        assert!(gate.resume());
        assert!(gate.enter().is_some());
    }

    #[test]
    fn timeout_never_reopens_an_active_engine() {
        let gate = CallbackGate::default();
        let active = gate.enter().unwrap();
        assert!(!gate.suspend_and_wait_for(Duration::ZERO));
        assert!(!gate.resume());
        assert!(gate.enter().is_none());
        drop(active);
        assert!(gate.suspend_and_wait());
        assert!(gate.resume());
    }
}
