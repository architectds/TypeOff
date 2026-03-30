use rdev::{listen, Event, EventType, Key};
use std::sync::mpsc::Sender;
use std::time::Instant;

/// Listen for double-shift (two taps within 400ms).
/// Sends a signal on each double-shift detected.
pub fn listen_double_shift(tx: Sender<()>) {
    let mut last_shift_release = Instant::now() - std::time::Duration::from_secs(10);

    listen(move |event: Event| match event.event_type {
        EventType::KeyRelease(key) => {
            if key == Key::ShiftLeft || key == Key::ShiftRight {
                let now = Instant::now();
                if now.duration_since(last_shift_release).as_millis() < 500 {
                    let _ = tx.send(());
                    last_shift_release = Instant::now() - std::time::Duration::from_secs(10);
                } else {
                    last_shift_release = now;
                }
            }
        }
        _ => {}
    })
    .expect("Failed to listen for hotkeys");
}
