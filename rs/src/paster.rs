/// Cross-platform text paste into active application.
///
/// Mac: CGEvent Cmd+V (no osascript, no Accessibility workarounds)
/// Windows/Linux: Ctrl+V via enigo
use arboard::Clipboard;
use std::thread;
use std::time::Duration;

pub fn copy_text(text: &str) -> Result<(), String> {
    if text.is_empty() {
        return Ok(());
    }

    match Clipboard::new() {
        Ok(mut clipboard) => clipboard
            .set_text(text.to_string())
            .map_err(|e| format!("Failed to set clipboard: {}", e)),
        Err(e) => Err(format!("Failed to open clipboard: {}", e)),
    }
}

/// Copy text to clipboard and simulate paste keystroke.
pub fn paste_text(text: &str) {
    if text.is_empty() {
        return;
    }

    if let Err(e) = copy_text(text) {
        eprintln!("[typeoff] {}", e);
        return;
    }

    thread::sleep(Duration::from_millis(100));

    #[cfg(target_os = "macos")]
    paste_macos();

    #[cfg(target_os = "windows")]
    paste_windows();

    #[cfg(target_os = "linux")]
    paste_linux();
}

#[cfg(target_os = "macos")]
fn paste_macos() {
    // Use CGEvent directly — bypasses osascript permission issues
    // CGEvent posting requires the app to have Accessibility permission,
    // but works from any process (no parent chain dependency)
    unsafe {
        use core_graphics::event::{CGEvent, CGEventFlags, CGKeyCode, EventField};
        use core_graphics::event_source::{CGEventSource, CGEventSourceStateID};

        let source = CGEventSource::new(CGEventSourceStateID::HIDSystemState);
        let source = match source {
            Ok(s) => s,
            Err(_) => {
                eprintln!("[typeoff] CGEvent source failed, trying enigo fallback");
                paste_macos_enigo();
                return;
            }
        };

        // Key code 9 = 'v' on macOS
        const V_KEY: CGKeyCode = 9;

        // Cmd+V down
        if let Ok(event) = CGEvent::new_keyboard_event(source.clone(), V_KEY, true) {
            event.set_flags(CGEventFlags::CGEventFlagCommand);
            event.post(core_graphics::event::CGEventTapLocation::HID);
        }

        thread::sleep(Duration::from_millis(20));

        // Cmd+V up
        if let Ok(event) = CGEvent::new_keyboard_event(source, V_KEY, false) {
            event.set_flags(CGEventFlags::CGEventFlagCommand);
            event.post(core_graphics::event::CGEventTapLocation::HID);
        }
    }
}

#[cfg(target_os = "macos")]
fn paste_macos_enigo() {
    use enigo::{Enigo, Key, Keyboard, Settings};
    if let Ok(mut enigo) = Enigo::new(&Settings::default()) {
        let _ = enigo.key(Key::Meta, enigo::Direction::Press);
        let _ = enigo.key(Key::Unicode('v'), enigo::Direction::Click);
        let _ = enigo.key(Key::Meta, enigo::Direction::Release);
    }
}

#[cfg(target_os = "windows")]
fn paste_windows() {
    use enigo::{Enigo, Key, Keyboard, Settings};
    if let Ok(mut enigo) = Enigo::new(&Settings::default()) {
        let _ = enigo.key(Key::Control, enigo::Direction::Press);
        let _ = enigo.key(Key::Unicode('v'), enigo::Direction::Click);
        let _ = enigo.key(Key::Control, enigo::Direction::Release);
    }
}

#[cfg(target_os = "linux")]
fn paste_linux() {
    use enigo::{Enigo, Key, Keyboard, Settings};
    if let Ok(mut enigo) = Enigo::new(&Settings::default()) {
        let _ = enigo.key(Key::Control, enigo::Direction::Press);
        let _ = enigo.key(Key::Unicode('v'), enigo::Direction::Click);
        let _ = enigo.key(Key::Control, enigo::Direction::Release);
    }
}
