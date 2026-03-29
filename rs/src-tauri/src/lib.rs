use serde::{Deserialize, Serialize};
use std::panic;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

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
}

// ─── Models / Languages / Hotkeys lists ──────────────────────────

#[derive(Serialize)]
struct ModelInfo { id: String, name: String, desc: String }

#[derive(Serialize)]
struct LangInfo { id: String, name: String }

#[derive(Serialize)]
struct HotkeyInfo { id: String, name: String }

fn get_models_list() -> Vec<ModelInfo> {
    vec![
        ModelInfo { id: "small".into(), name: "Small".into(), desc: "~460MB, good balance (multilingual)".into() },
        ModelInfo { id: "base".into(), name: "Base".into(), desc: "~140MB, fast, basic accuracy".into() },
        ModelInfo { id: "tiny".into(), name: "Tiny".into(), desc: "~75MB, fastest, lower accuracy".into() },
        ModelInfo { id: "medium".into(), name: "Medium".into(), desc: "~1.5GB, high accuracy".into() },
        ModelInfo { id: "large-v3".into(), name: "Large v3".into(), desc: "~3GB, best accuracy, slowest".into() },
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

// ─── Tauri Commands ──────────────────────────────────────────────

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
    let mut config = state.config.lock().unwrap();
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
    serde_json::json!({"ok": true, "message": "Settings saved"})
}

#[tauri::command]
fn get_models() -> Vec<ModelInfo> { get_models_list() }

#[tauri::command]
fn get_languages() -> Vec<LangInfo> { get_languages_list() }

#[tauri::command]
fn get_hotkeys() -> Vec<HotkeyInfo> { get_hotkeys_list() }

#[tauri::command]
fn toggle_recording(state: tauri::State<TauriState>) {
    let current_status = state.state.lock().unwrap().status.clone();

    match current_status.as_str() {
        "recording" => {
            state.state.lock().unwrap().status = "stopping".into();
        }
        "ready" => {
            let has_model = state.transcriber.lock().unwrap().is_some();
            if !has_model {
                return;
            }

            state.state.lock().unwrap().status = "recording".into();

            let app_state = Arc::clone(&state.state);
            let config = state.config.lock().unwrap().clone();
            let transcriber = Arc::clone(&state.transcriber);

            thread::spawn(move || {
                // catch_unwind so panics don't kill the app — just reset state
                let result = panic::catch_unwind(panic::AssertUnwindSafe(|| {
                    run_session(&config, &transcriber, &app_state);
                }));

                if let Err(e) = result {
                    eprintln!("[typeoff] Session panicked: {:?}", e);
                }

                // Always ensure state returns to ready, even after panic
                let mut s = app_state.lock().unwrap();
                s.status = "ready".into();
                s.message = "Ready".into();
                s.rms = 0.0;
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
                }
                "ready" => {
                    let has_model = transcriber_hotkey.lock().unwrap().is_some();
                    if !has_model {
                        continue;
                    }
                    state_hotkey.lock().unwrap().status = "recording".into();

                    let app_state = Arc::clone(&state_hotkey);
                    let config = config_hotkey.lock().unwrap().clone();
                    let transcriber = Arc::clone(&transcriber_hotkey);

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
                    });
                }
                _ => {}
            }
        }
    });

    // Clone ref for cleanup on exit
    let transcriber_cleanup = Arc::clone(&tauri_state.transcriber);

    tauri::Builder::default()
        .manage(tauri_state)
        .invoke_handler(tauri::generate_handler![
            get_state,
            get_config,
            save_config,
            get_models,
            get_languages,
            get_hotkeys,
            toggle_recording,
        ])
        .on_window_event(move |_window, event| {
            // Drop Metal-backed models BEFORE process exit to avoid
            // ggml_metal_rsets_free abort during __cxa_finalize_ranges
            if let tauri::WindowEvent::Destroyed = event {
                if let Ok(mut t) = transcriber_cleanup.lock() {
                    *t = None; // drop Transcriber → drops WhisperContext → clean Metal free
                }
            }
        })
        .run(tauri::generate_context!())
        .expect("error while running Typeoff");
}
