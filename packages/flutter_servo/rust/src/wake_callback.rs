use std::ffi::c_void;
use std::sync::Mutex;

pub type Callback = extern "C" fn(*mut c_void);

#[derive(Default)]
pub struct WakeCallback {
    target: Mutex<Option<(Callback, usize)>>,
}

impl WakeCallback {
    // The host keeps the opaque context alive until set(None, ...) returns.
    // Callbacks may run on any Servo thread and must only enqueue host work;
    // they must not reenter Servo or change this registration.
    pub fn set(&self, callback: Option<Callback>, context: *mut c_void) {
        *self.target.lock().unwrap() = callback.map(|callback| (callback, context as usize));
    }

    pub fn notify(&self) {
        // Holding the lock through dispatch makes unregister a lifetime barrier.
        if let Some((callback, context)) = *self.target.lock().unwrap() {
            callback(context as *mut c_void);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;

    extern "C" fn count(context: *mut c_void) {
        let counter = unsafe { &*context.cast::<AtomicUsize>() };
        counter.fetch_add(1, Ordering::Relaxed);
    }

    #[test]
    fn unregister_stops_notifications_from_other_threads() {
        let wake = Arc::new(WakeCallback::default());
        let counter = AtomicUsize::new(0);
        wake.set(
            Some(count),
            (&counter as *const AtomicUsize).cast_mut().cast(),
        );
        let worker = wake.clone();
        std::thread::spawn(move || worker.notify()).join().unwrap();
        assert_eq!(counter.load(Ordering::Relaxed), 1);
        wake.set(None, std::ptr::null_mut());
        let worker = wake.clone();
        std::thread::spawn(move || worker.notify()).join().unwrap();
        assert_eq!(counter.load(Ordering::Relaxed), 1);
    }
}
