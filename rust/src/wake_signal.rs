use std::io;
use std::os::fd::{IntoRawFd, RawFd};
use std::os::unix::net::UnixDatagram;

/// A bounded, nonblocking notification channel consumed by GLib's fd source.
pub(crate) struct WakeSignal {
    sender: UnixDatagram,
    receiver: UnixDatagram,
}

impl WakeSignal {
    pub(crate) fn new() -> io::Result<Self> {
        let (sender, receiver) = UnixDatagram::pair()?;
        sender.set_nonblocking(true)?;
        receiver.set_nonblocking(true)?;
        Ok(Self { sender, receiver })
    }

    pub(crate) fn notify(&self) {
        // A full socket already represents a pending wake; never block Servo.
        let _ = self.sender.send(&[1]);
    }

    pub(crate) fn clone_receiver_fd(&self) -> io::Result<RawFd> {
        self.receiver.try_clone().map(IntoRawFd::into_raw_fd)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::fd::FromRawFd;

    #[test]
    fn worker_wakes_are_readable_and_saturation_never_blocks() {
        let signal = std::sync::Arc::new(WakeSignal::new().unwrap());
        let receiver = unsafe { UnixDatagram::from_raw_fd(signal.clone_receiver_fd().unwrap()) };
        let worker_signal = signal.clone();
        std::thread::spawn(move || {
            for _ in 0..100_000 {
                worker_signal.notify();
            }
        })
        .join()
        .unwrap();
        let mut buffer = [0; 64];
        assert!(receiver.recv(&mut buffer).unwrap() > 0);
        while receiver.recv(&mut buffer).is_ok() {}
        signal.notify();
        assert_eq!(receiver.recv(&mut buffer).unwrap(), 1);
    }
}
