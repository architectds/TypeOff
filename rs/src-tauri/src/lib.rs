use serde::{Deserialize, Serialize};
use std::panic;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};
use tauri::image::Image as TauriImage;
use tauri::Manager;
use tauri::menu::{MenuBuilder, MenuItemBuilder};
use tauri::tray::TrayIconBuilder;

use typeoff::audio_filter;
use typeoff::config::Config;
use typeoff::corrector::Corrector;
use typeoff::fillers;
use typeoff::paster;
use typeoff::recorder::Recorder;
use typeoff::streamer::StreamingTranscriber;
use typeoff::transcriber::Transcriber;
use typeoff::vad::Vad;

// ─── Shared State ────────────────────────────────────────────────

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct AppState {
    pub status: String,
    pub text: String,
    pub elapsed: f32,
    pub message: String,
    pub rms: f32,
}

impl Default for AppState {
    fn default() -> Self {
        Self {
            status: "loading".into(),
            text: String::new(),
            elapsed: 0.0,
            message: "Loading model...".into(),
            rms: 0.0,
        }
    }
}

pub struct TauriState {
    pub state: Arc<Mutex<AppState>>,
    pub config: Arc<Mutex<Config>>,
    pub transcriber: Arc<Mutex<Option<Transcriber>>>,
    pub app_handle: Arc<Mutex<Option<tauri::AppHandle>>>,
}

// Tray icon IDs
const TRAY_ID: &str = "typeoff-tray";

fn set_tray_recording(app: &tauri::AppHandle, recording: bool) {
    if let Some(tray) = app.tray_by_id(TRAY_ID) {
        let icon_bytes = if recording {
            include_bytes!("../icons/toff_tray_recording.png").as_slice()
        } else {
            include_bytes!("../icons/toff_tray_idle.png").as_slice()
        };
        if let Ok(icon) = TauriImage::from_bytes(icon_bytes) {
            let _ = tray.set_icon(Some(icon));
        }
        let tooltip = if recording { "Typeoff — Recording..." } else { "Typeoff — Double Shift to record" };
        let _ = tray.set_tooltip(Some(tooltip));
    }
}

// ─── Models / Languages / Hotkeys lists ──────────────────────────

#[derive(Serialize)]
struct ModelInfo { id: String, name: String, desc: String, size: String, url: String }

#[derive(Serialize)]
struct LangInfo { id: String, name: String }

#[derive(Serialize)]
struct HotkeyInfo { id: String, name: String }

#[derive(Serialize)]
struct ModelStatus { installed: bool, path: String, model: String }

const WHISPER_BASE_URL: &str = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main";

fn get_models_list() -> Vec<ModelInfo> {
    vec![
        ModelInfo {
            id: "small".into(), name: "Small".into(),
            desc: "Good balance (multilingual)".into(),
            size: "465 MB".into(),
            url: format!("{}/ggml-small.bin", WHISPER_BASE_URL),
        },
        ModelInfo {
            id: "base".into(), name: "Base".into(),
            desc: "Fast, basic accuracy".into(),
            size: "142 MB".into(),
            url: format!("{}/ggml-base.bin", WHISPER_BASE_URL),
        },
        ModelInfo {
            id: "tiny".into(), name: "Tiny".into(),
            desc: "Fastest, lower accuracy".into(),
            size: "75 MB".into(),
            url: format!("{}/ggml-tiny.bin", WHISPER_BASE_URL),
        },
        ModelInfo {
            id: "medium".into(), name: "Medium".into(),
            desc: "High accuracy, slower".into(),
            size: "1.5 GB".into(),
            url: format!("{}/ggml-medium.bin", WHISPER_BASE_URL),
        },
        ModelInfo {
            id: "large-v3".into(), name: "Large v3".into(),
            desc: "Best accuracy, slowest".into(),
            size: "3.1 GB".into(),
            url: format!("{}/ggml-large-v3.bin", WHISPER_BASE_URL),
        },
    ]
}

fn get_languages_list() -> Vec<LangInfo> {
    vec![
        LangInfo { id: "auto".into(), name: "Auto-detect".into() },
        LangInfo { id: "en".into(), name: "English".into() },
        LangInfo { id: "zh".into(), name: "Chinese / 中文".into() },
        LangInfo { id: "ja".into(), name: "Japanese / 日本語".into() },
        LangInfo { id: "ko".into(), name: "Korean / 한국어".into() },
        LangInfo { id: "es".into(), name: "Spanish / Español".into() },
        LangInfo { id: "fr".into(), name: "French / Français".into() },
        LangInfo { id: "de".into(), name: "German / Deutsch".into() },
    ]
}

fn get_hotkeys_list() -> Vec<HotkeyInfo> {
    vec![
        HotkeyInfo { id: "double_shift".into(), name: "Double Shift (recommended)".into() },
        HotkeyInfo { id: "ctrl+shift+space".into(), name: "Ctrl + Shift + Space".into() },
        HotkeyInfo { id: "ctrl+space".into(), name: "Ctrl + Space".into() },
    ]
}

// ─── Permission Checks ───────────────────────────────────────────

#[derive(Serialize)]
struct PermissionStatus {
    accessibility: bool,
    microphone: bool,
}

#[cfg(target_os = "macos")]
fn check_accessibility() -> bool {
    // Test if osascript can actually send keystrokes (not just query)
    let output = std::process::Command::new("osascript")
        .arg("-e")
        .arg("tell application \"System Events\" to keystroke \"\"")
        .output();
    match output {
        Ok(o) => o.status.success(),
        Err(_) => false,
    }
}

#[cfg(not(target_os = "macos"))]
fn check_accessibility() -> bool {
    true // Not needed on Windows/Linux
}

// ─── Tauri Commands ──────────────────────────────────────────────

#[tauri::command]
fn check_permissions() -> PermissionStatus {
    PermissionStatus {
        accessibility: check_accessibility(),
        microphone: true, // macOS auto-prompts for mic
    }
}

/// Open macOS System Preferences to the Accessibility pane
#[tauri::command]
fn open_accessibility_settings() {
    #[cfg(target_os = "macos")]
    {
        let _ = std::process::Command::new("open")
            .arg("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            .spawn();
    }
}

#[tauri::command]
fn get_state(state: tauri::State<TauriState>) -> AppState {
    state.state.lock().unwrap().clone()
}

#[tauri::command]
fn get_config(state: tauri::State<TauriState>) -> Config {
    state.config.lock().unwrap().clone()
}

#[tauri::command]
fn save_config(state: tauri::State<TauriState>, new_config: serde_json::Value) -> serde_json::Value {
    let old_model;
    let new_model;

    {
        let mut config = state.config.lock().unwrap();
        old_model = config.model.clone();

        if let Ok(merged) = serde_json::to_value(&*config) {
            if let serde_json::Value::Object(mut map) = merged {
                if let serde_json::Value::Object(new_map) = new_config {
                    for (k, v) in new_map {
                        map.insert(k, v);
                    }
                }
                if let Ok(updated) = serde_json::from_value::<Config>(serde_json::Value::Object(map)) {
                    updated.save();
                    *config = updated;
                }
            }
        }

        new_model = config.model.clone();
    }

    // If model changed, check if new model exists and reload
    if old_model != new_model {
        let config = state.config.lock().unwrap().clone();
        let model_path = config.get_model_path();

        if std::path::Path::new(&model_path).exists() {
            // Model exists — reload in background
            let app_state = Arc::clone(&state.state);
            let transcriber_ref = Arc::clone(&state.transcriber);

            {
                let mut s = app_state.lock().unwrap();
                s.status = "loading".into();
                s.message = format!("Loading {}...", new_model);
            }

            thread::spawn(move || {
                let t = Transcriber::new(&config);
                *transcriber_ref.lock().unwrap() = Some(t);
                let mut s = app_state.lock().unwrap();
                s.status = "ready".into();
                s.message = format!("Ready — whisper-{}", config.model);
            });

            return serde_json::json!({"ok": true, "message": "Loading new model..."});
        } else {
            // Model doesn't exist — tell UI to show download prompt
            return serde_json::json!({"ok": true, "message": "Model not found", "needsDownload": true});
        }
    }

    serde_json::json!({"ok": true, "message": "Settings saved"})
}

#[tauri::command]
fn get_models() -> Vec<ModelInfo> { get_models_list() }

#[tauri::command]
fn get_languages() -> Vec<LangInfo> { get_languages_list() }

#[tauri::command]
fn get_hotkeys() -> Vec<HotkeyInfo> { get_hotkeys_list() }

/// Check if the current whisper model is installed
#[tauri::command]
fn check_model(state: tauri::State<TauriState>) -> ModelStatus {
    let config = state.config.lock().unwrap();
    let path = config.get_model_path();
    let installed = std::path::Path::new(&path).exists();
    ModelStatus {
        installed,
        path,
        model: config.model.clone(),
    }
}

/// Download a whisper model file. Returns progress messages via state.
#[tauri::command]
fn download_model(state: tauri::State<TauriState>, model_id: String) -> Result<String, String> {
    let models = get_models_list();
    let model = models.iter().find(|m| m.id == model_id)
        .ok_or_else(|| format!("Unknown model: {}", model_id))?;

    let models_dir = Config::models_dir();
    let dest = models_dir.join(format!("ggml-{}.bin", model_id));

    if dest.exists() {
        return Ok(format!("Model already exists: {}", dest.display()));
    }

    // Update UI message
    {
        let mut s = state.state.lock().unwrap();
        s.status = "loading".into();
        s.message = format!("Downloading {} ({})...", model.name, model.size);
    }

    // Download using curl (available on Mac/Win/Linux)
    let result = std::process::Command::new("curl")
        .args(["-L", "-o", &dest.to_string_lossy(), &model.url])
        .output();

    match result {
        Ok(output) if output.status.success() => {
            // Reload the model
            let config = state.config.lock().unwrap().clone();
            let t = Transcriber::new(&config);
            *state.transcriber.lock().unwrap() = Some(t);

            let mut s = state.state.lock().unwrap();
            s.status = "ready".into();
            s.message = format!("Ready — whisper-{}", model_id);

            Ok(format!("Downloaded to {}", dest.display()))
        }
        Ok(output) => {
            let mut s = state.state.lock().unwrap();
            s.status = "ready".into();
            s.message = "Download failed".into();
            Err(format!("curl failed: {}", String::from_utf8_lossy(&output.stderr)))
        }
        Err(e) => {
            let mut s = state.state.lock().unwrap();
            s.status = "ready".into();
            s.message = "Download failed".into();
            Err(format!("Failed to run curl: {}", e))
        }
    }
}

#[tauri::command]
fn toggle_recording(state: tauri::State<TauriState>) {
    let current_status = state.state.lock().unwrap().status.clone();

    match current_status.as_str() {
        "recording" => {
            state.state.lock().unwrap().status = "stopping".into();
            // Switch tray icon back to idle immediately
            if let Some(ref app) = *state.app_handle.lock().unwrap() {
                set_tray_recording(app, false);
            }
        }
        "ready" => {
            let has_model = state.transcriber.lock().unwrap().is_some();
            if !has_model {
                return;
            }

            state.state.lock().unwrap().status = "recording".into();

            // Switch tray icon to recording
            if let Some(ref app) = *state.app_handle.lock().unwrap() {
                set_tray_recording(app, true);
            }

            let app_state = Arc::clone(&state.state);
            let config = state.config.lock().unwrap().clone();
            let transcriber = Arc::clone(&state.transcriber);
            let app_handle = Arc::clone(&state.app_handle);

            thread::spawn(move || {
                let result = panic::catch_unwind(panic::AssertUnwindSafe(|| {
                    run_session(&config, &transcriber, &app_state);
                }));

                if let Err(e) = result {
                    eprintln!("[typeoff] Session panicked: {:?}", e);
                }

                let mut s = app_state.lock().unwrap();
                s.status = "ready".into();
                s.message = "Ready".into();
                s.rms = 0.0;

                // Switch tray icon back to idle
                if let Some(ref app) = *app_handle.lock().unwrap() {
                    set_tray_recording(app, false);
                }
            });
        }
        _ => {}
    }
}

// ─── Session ─────────────────────────────────────────────────────

fn run_session(
    config: &Config,
    transcriber: &Arc<Mutex<Option<Transcriber>>>,
    state: &Arc<Mutex<AppState>>,
) {
    let mut recorder = Recorder::new(config.sample_rate);
    let vad = Vad::new(config.silence_duration, config.sample_rate);
    let mut streamer = StreamingTranscriber::new();
    let mut corrector = Corrector::new(
        &config.correction_mode,
        config.get_correction_model_path(),
    );

    {
        let mut s = state.lock().unwrap();
        s.status = "recording".into();
        s.text.clear();
        s.elapsed = 0.0;
        s.message = "Listening...".into();
        s.rms = 0.0;
    }

    recorder.start();
    let start = Instant::now();
    let mut last_transcribe = Instant::now() - Duration::from_secs(10);

    // Recording loop
    loop {
        thread::sleep(Duration::from_millis(200));

        let status = state.lock().unwrap().status.clone();
        if status == "stopping" {
            break;
        }

        let audio = recorder.get_audio();
        let duration = audio.len() as f32 / config.sample_rate as f32;
        let elapsed = start.elapsed().as_secs_f32();

        {
            let mut s = state.lock().unwrap();
            s.elapsed = elapsed;
            if audio.len() > 1600 {
                let tail = &audio[audio.len() - 1600..];
                s.rms = (tail.iter().map(|x| x * x).sum::<f32>() / tail.len() as f32).sqrt();
            }
        }

        if duration > config.max_duration {
            break;
        }

        if config.auto_stop_silence && duration > config.silence_duration + 1.0 {
            if vad.has_speech(&audio) && vad.detect_end_of_speech(&audio) {
                break;
            }
        }

        if duration >= 1.5 && last_transcribe.elapsed() >= Duration::from_secs(3) {
            if !vad.has_speech(&audio) {
                continue;
            }

            let filtered = audio_filter::voice_filter(&audio, config.sample_rate);

            let transcriber_guard = transcriber.lock().unwrap();
            if let Some(ref t) = *transcriber_guard {
                let lang = config.language.as_deref();
                let (new_sentence, _pending) = streamer.rolling_transcribe(&filtered, t, lang);
                drop(transcriber_guard);
                last_transcribe = Instant::now();

                if let Some(sentence) = new_sentence {
                    let mut cleaned = fillers::remove_fillers(&sentence);
                    if corrector.is_enabled() {
                        cleaned = corrector.correct(&cleaned);
                    }
                    if config.auto_paste && !cleaned.is_empty() {
                        let _ = panic::catch_unwind(|| {
                            paster::paste_text(&cleaned);
                        });
                    }
                }

                let display = streamer.get_display_text();
                if !display.is_empty() {
                    state.lock().unwrap().text = display;
                }
            }
        }
    }

    // Final pass
    {
        let mut s = state.lock().unwrap();
        s.status = "transcribing".into();
        s.message = "Transcribing...".into();
    }

    let raw_audio = recorder.stop();

    if !vad.has_speech(&raw_audio) {
        let mut s = state.lock().unwrap();
        s.status = "ready".into();
        s.message = "No speech detected".into();
        s.text.clear();
        return;
    }

    let audio = audio_filter::voice_filter(&raw_audio, config.sample_rate);

    let transcriber_guard = transcriber.lock().unwrap();
    if let Some(ref t) = *transcriber_guard {
        let lang = config.language.as_deref();
        let (remainder, full_text) = streamer.final_transcribe(&audio, t, lang);
        drop(transcriber_guard);

        if config.auto_paste {
            if let Some(ref text) = remainder {
                let mut cleaned = fillers::remove_fillers(text);
                if corrector.is_enabled() {
                    cleaned = corrector.correct(&cleaned);
                }
                if !cleaned.is_empty() {
                    let _ = panic::catch_unwind(|| {
                        paster::paste_text(&cleaned);
                    });
                }
            }
        }

        {
            let mut s = state.lock().unwrap();
            s.status = "done".into();
            s.text = full_text;
            s.message = "Done!".into();
        }

        thread::sleep(Duration::from_secs(2));
    }

    // Caller (toggle_recording) handles resetting to "ready"
}

// ─── App Setup ───────────────────────────────────────────────────

pub fn run() {
    let config = Config::load();

    let tauri_state = TauriState {
        state: Arc::new(Mutex::new(AppState::default())),
        config: Arc::new(Mutex::new(config.clone())),
        transcriber: Arc::new(Mutex::new(None)),
        app_handle: Arc::new(Mutex::new(None)),
    };

    // Load model in background
    let transcriber_ref = Arc::clone(&tauri_state.transcriber);
    let state_ref = Arc::clone(&tauri_state.state);
    let config_clone = config.clone();

    thread::spawn(move || {
        let t = Transcriber::new(&config_clone);
        *transcriber_ref.lock().unwrap() = Some(t);
        let mut s = state_ref.lock().unwrap();
        s.status = "ready".into();
        s.message = format!("Ready — whisper-{}", config_clone.model);
    });

    // Hotkey listener on dedicated thread
    let state_hotkey = Arc::clone(&tauri_state.state);
    let config_hotkey = Arc::clone(&tauri_state.config);
    let transcriber_hotkey = Arc::clone(&tauri_state.transcriber);
    let app_handle_hotkey = Arc::clone(&tauri_state.app_handle);

    thread::spawn(move || {
        let (tx, rx) = std::sync::mpsc::channel::<()>();
        thread::spawn(move || {
            typeoff::hotkey::listen_double_shift(tx);
        });

        for () in rx {
            let current_status = state_hotkey.lock().unwrap().status.clone();
            match current_status.as_str() {
                "recording" => {
                    state_hotkey.lock().unwrap().status = "stopping".into();
                    // Switch tray icon back to idle immediately
                    if let Some(ref app) = *app_handle_hotkey.lock().unwrap() {
                        set_tray_recording(app, false);
                    }
                }
                "ready" => {
                    let has_model = transcriber_hotkey.lock().unwrap().is_some();
                    if !has_model {
                        continue;
                    }
                    state_hotkey.lock().unwrap().status = "recording".into();

                    // Switch tray to recording
                    if let Some(ref app) = *app_handle_hotkey.lock().unwrap() {
                        set_tray_recording(app, true);
                    }

                    let app_state = Arc::clone(&state_hotkey);
                    let config = config_hotkey.lock().unwrap().clone();
                    let transcriber = Arc::clone(&transcriber_hotkey);
                    let app_handle = Arc::clone(&app_handle_hotkey);

                    thread::spawn(move || {
                        let result = panic::catch_unwind(panic::AssertUnwindSafe(|| {
                            run_session(&config, &transcriber, &app_state);
                        }));
                        if let Err(e) = result {
                            eprintln!("[typeoff] Session panicked: {:?}", e);
                        }
                        let mut s = app_state.lock().unwrap();
                        s.status = "ready".into();
                        s.message = "Ready".into();
                        s.rms = 0.0;

                        // Switch tray back to idle
                        if let Some(ref app) = *app_handle.lock().unwrap() {
                            set_tray_recording(app, false);
                        }
                    });
                }
                _ => {}
            }
        }
    });

    // Clone ref for cleanup on exit
    let transcriber_cleanup = Arc::clone(&tauri_state.transcriber);

    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| {
            // Second instance tried to launch — show the existing window instead
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.show();
                let _ = window.set_focus();
            }
        }))
        .plugin(tauri_plugin_autostart::init(
            tauri_plugin_autostart::MacosLauncher::LaunchAgent,
            None,
        ))
        .manage(tauri_state)
        .invoke_handler(tauri::generate_handler![
            get_state,
            get_config,
            save_config,
            get_models,
            get_languages,
            get_hotkeys,
            check_model,
            download_model,
            check_permissions,
            open_accessibility_settings,
            toggle_recording,
        ])
        .setup(|app| {
            // Store app handle for tray icon switching from background threads
            let state: tauri::State<TauriState> = app.state();
            *state.app_handle.lock().unwrap() = Some(app.handle().clone());

            // ─── System Tray ─────────────────────────────────
            let show = MenuItemBuilder::with_id("show", "Show Typeoff").build(app)?;
            let quit = MenuItemBuilder::with_id("quit", "Quit").build(app)?;
            let menu = MenuBuilder::new(app)
                .item(&show)
                .separator()
                .item(&quit)
                .build()?;

            let idle_icon = TauriImage::from_bytes(include_bytes!("../icons/toff_tray_idle.png"))?;

            let _tray = TrayIconBuilder::with_id(TRAY_ID)
                .icon(idle_icon)
                .menu(&menu)
                .tooltip("Typeoff — Double Shift to record")
                .on_menu_event(|app, event| {
                    match event.id().as_ref() {
                        "show" => {
                            if let Some(window) = app.get_webview_window("main") {
                                let _ = window.show();
                                let _ = window.set_focus();
                            }
                        }
                        "quit" => {
                            app.exit(0);
                        }
                        _ => {}
                    }
                })
                .on_tray_icon_event(|tray, event| {
                    // Double-click tray icon → show/hide window
                    if let tauri::tray::TrayIconEvent::DoubleClick { .. } = event {
                        let app = tray.app_handle();
                        if let Some(window) = app.get_webview_window("main") {
                            if window.is_visible().unwrap_or(false) {
                                let _ = window.hide();
                            } else {
                                let _ = window.show();
                                let _ = window.set_focus();
                            }
                        }
                    }
                })
                .build(app)?;

            // ─── Request Accessibility permission on startup ─────
            #[cfg(target_os = "macos")]
            {
                // AXIsProcessTrustedWithOptions with prompt=true shows the
                // macOS permission dialog if not yet granted. This is the
                // standard way apps like Karabiner, Rectangle, etc. request it.
                unsafe {
                    extern "C" {
                        fn AXIsProcessTrustedWithOptions(options: *const std::ffi::c_void) -> bool;
                    }
                    use core_foundation::base::TCFType;
                    use core_foundation::boolean::CFBoolean;
                    use core_foundation::dictionary::CFDictionary;
                    use core_foundation::string::CFString;

                    let key = CFString::new("AXTrustedCheckOptionPrompt");
                    let value = CFBoolean::true_value();
                    let options = CFDictionary::from_CFType_pairs(&[(key, value)]);
                    let trusted = AXIsProcessTrustedWithOptions(options.as_concrete_TypeRef() as *const _);
                    if trusted {
                        println!("[typeoff] Accessibility permission: granted");
                    } else {
                        println!("[typeoff] Accessibility permission: requesting...");
                    }
                }
            }

            Ok(())
        })
        .on_window_event(move |window, event| {
            match event {
                // Close button → hide to tray instead of quitting
                tauri::WindowEvent::CloseRequested { api, .. } => {
                    let _ = window.hide();
                    api.prevent_close();
                }
                // Actual destroy (from quit menu) → clean up Metal models
                tauri::WindowEvent::Destroyed => {
                    if let Ok(mut t) = transcriber_cleanup.lock() {
                        *t = None;
                    }
                }
                _ => {}
            }
        })
        .run(tauri::generate_context!())
        .expect("error while running Typeoff");
}
