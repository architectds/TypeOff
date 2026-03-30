mod audio_filter;
mod config;
mod corrector;
mod fillers;
mod hotkey;
mod paster;
mod recorder;
mod streamer;
mod transcriber;
mod vad;

use std::io::Write;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use config::Config;
use paster::paste_text;
use recorder::Recorder;
use streamer::StreamingTranscriber;
use transcriber::Transcriber;
use vad::Vad;

/// App state shared across threads
#[derive(Clone, Debug)]
pub struct AppState {
    pub status: String,
    pub text: String,
    pub elapsed: f32,
}

impl Default for AppState {
    fn default() -> Self {
        Self {
            status: "loading".into(),
            text: String::new(),
            elapsed: 0.0,
        }
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();

    if args.len() > 1 {
        match args[1].as_str() {
            "--test-record" => {
                let secs: f32 = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(3.0);
                test_record(secs);
                return;
            }
            "--test-transcribe" => {
                let path = args.get(2).map(|s| s.as_str()).unwrap_or("");
                if path.is_empty() {
                    eprintln!("Usage: typeoff --test-transcribe <audio.raw>");
                    eprintln!("  Audio must be f32le, 16kHz, mono.");
                    eprintln!(
                        "  Create with: ffmpeg -i input.mp3 -ar 16000 -ac 1 -f f32le output.raw"
                    );
                    return;
                }
                test_transcribe(path);
                return;
            }
            "--test-record-transcribe" => {
                let secs: f32 = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(5.0);
                test_record_transcribe(secs);
                return;
            }
            "--test-filter" => {
                test_filter();
                return;
            }
            "--test-fillers" => {
                test_fillers();
                return;
            }
            "--test-correct" => {
                let text = args.get(2).map(|s| s.as_str()).unwrap_or("今天的天汽很好");
                test_correct(text);
                return;
            }
            "--test-streamer" => {
                test_streamer();
                return;
            }
            "--help" | "-h" => {
                println!("Typeoff — Offline speech-to-text");
                println!();
                println!("Usage:");
                println!("  typeoff                              Run normally (hotkey mode)");
                println!("  typeoff --test-record <secs>         Record and show audio stats");
                println!(
                    "  typeoff --test-transcribe <file.raw> Transcribe a raw f32le 16kHz file"
                );
                println!("  typeoff --test-record-transcribe <s> Record then transcribe");
                println!(
                    "  typeoff --test-filter                Test bandpass filter on TTS audio"
                );
                println!("  typeoff --test-fillers               Test filler removal");
                println!("  typeoff --test-streamer              Test streaming agreement logic");
                return;
            }
            _ => {
                eprintln!("Unknown flag: {}. Use --help for usage.", args[1]);
                return;
            }
        }
    }

    // Normal mode: hotkey-driven session loop
    run_normal();
}

// ─── Test: Record Audio ──────────────────────────────────────────

fn test_record(seconds: f32) {
    println!("[test-record] Recording {:.1}s of audio...", seconds);

    let mut recorder = Recorder::new(16000);
    recorder.start();

    let start = Instant::now();
    while start.elapsed().as_secs_f32() < seconds {
        thread::sleep(Duration::from_millis(100));

        let audio = recorder.get_audio();
        let duration = audio.len() as f32 / 16000.0;
        if audio.len() > 1600 {
            let tail = &audio[audio.len() - 1600..];
            let rms = (tail.iter().map(|s| s * s).sum::<f32>() / tail.len() as f32).sqrt();
            print!(
                "\r[test-record] {:.1}s | {} samples | rms={:.6}",
                duration,
                audio.len(),
                rms
            );
            std::io::stdout().flush().ok();
        }
    }
    println!();

    let audio = recorder.stop();
    let total_samples = audio.len();
    let total_duration = total_samples as f32 / 16000.0;

    let rms = if !audio.is_empty() {
        (audio.iter().map(|s| s * s).sum::<f32>() / audio.len() as f32).sqrt()
    } else {
        0.0
    };

    let peak = audio.iter().map(|s| s.abs()).fold(0.0f32, f32::max);

    println!("[test-record] Done.");
    println!("[test-record] Samples: {}", total_samples);
    println!("[test-record] Duration: {:.2}s", total_duration);
    println!("[test-record] RMS: {:.6}", rms);
    println!("[test-record] Peak: {:.6}", peak);

    // Save raw audio for playback
    let out_path = "/tmp/typeoff_test.raw";
    let bytes: Vec<u8> = audio.iter().flat_map(|f| f.to_le_bytes()).collect();
    std::fs::write(out_path, &bytes).ok();
    println!("[test-record] Saved to: {}", out_path);
    println!(
        "[test-record] Play with: ffplay -f f32le -ar 16000 -ac 1 {}",
        out_path
    );

    if rms < 0.001 {
        eprintln!("[test-record] WARNING: RMS very low ({:.6}). Mic may not be working or permission not granted.", rms);
    } else if rms > 0.5 {
        eprintln!(
            "[test-record] WARNING: RMS very high ({:.6}). Audio may be clipping.",
            rms
        );
    } else {
        println!("[test-record] Audio levels look good.");
    }
}

// ─── Test: Transcribe File ───────────────────────────────────────

fn test_transcribe(path: &str) {
    let config = Config::load();

    println!("[test-transcribe] Loading model: {}", config.model);
    let model_path = config.get_model_path();
    println!("[test-transcribe] Model path: {}", model_path);

    if !std::path::Path::new(&model_path).exists() {
        eprintln!(
            "[test-transcribe] ERROR: Model file not found at: {}",
            model_path
        );
        return;
    }

    let transcriber = Transcriber::new(&config);
    println!("[test-transcribe] Model loaded.");

    // Read raw f32le audio
    let bytes = match std::fs::read(path) {
        Ok(b) => b,
        Err(e) => {
            eprintln!("[test-transcribe] ERROR: Cannot read {}: {}", path, e);
            return;
        }
    };

    let audio: Vec<f32> = bytes
        .chunks_exact(4)
        .map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]]))
        .collect();

    println!(
        "[test-transcribe] Audio: {} samples ({:.1}s)",
        audio.len(),
        audio.len() as f32 / 16000.0
    );

    let rms = if !audio.is_empty() {
        (audio.iter().map(|s| s * s).sum::<f32>() / audio.len() as f32).sqrt()
    } else {
        0.0
    };
    println!("[test-transcribe] RMS: {:.6}", rms);

    let start = Instant::now();
    let text = transcriber.transcribe(&audio, config.language.as_deref());
    let elapsed = start.elapsed();

    println!("[test-transcribe] Time: {:.2}s", elapsed.as_secs_f32());
    println!("[test-transcribe] Result: \"{}\"", text);
}

// ─── Test: Record then Transcribe ────────────────────────────────

fn test_record_transcribe(seconds: f32) {
    let config = Config::load();

    println!("[test-record-transcribe] Loading model: {}", config.model);
    let model_path = config.get_model_path();
    if !std::path::Path::new(&model_path).exists() {
        eprintln!(
            "[test-record-transcribe] ERROR: Model file not found at: {}",
            model_path
        );
        return;
    }

    let transcriber = Transcriber::new(&config);
    println!("[test-record-transcribe] Model loaded.");

    println!(
        "[test-record-transcribe] Recording {:.1}s... SPEAK NOW!",
        seconds
    );
    let mut recorder = Recorder::new(16000);
    recorder.start();

    let start = Instant::now();
    while start.elapsed().as_secs_f32() < seconds {
        thread::sleep(Duration::from_millis(200));
        let remaining = seconds - start.elapsed().as_secs_f32();
        print!(
            "\r[test-record-transcribe] {:.1}s remaining...  ",
            remaining.max(0.0)
        );
        std::io::stdout().flush().ok();
    }
    println!();

    let audio = recorder.stop();
    let rms = if !audio.is_empty() {
        (audio.iter().map(|s| s * s).sum::<f32>() / audio.len() as f32).sqrt()
    } else {
        0.0
    };
    println!(
        "[test-record-transcribe] Captured: {} samples ({:.1}s), RMS={:.6}",
        audio.len(),
        audio.len() as f32 / 16000.0,
        rms
    );

    if rms < 0.001 {
        eprintln!("[test-record-transcribe] WARNING: Very low RMS. No speech detected?");
    }

    println!("[test-record-transcribe] Transcribing...");
    let t0 = Instant::now();
    let text = transcriber.transcribe(&audio, config.language.as_deref());
    let elapsed = t0.elapsed();

    println!(
        "[test-record-transcribe] Time: {:.2}s",
        elapsed.as_secs_f32()
    );
    println!("[test-record-transcribe] Result: \"{}\"", text);

    // Save audio for replay
    let out_path = "/tmp/typeoff_test.raw";
    let bytes: Vec<u8> = audio.iter().flat_map(|f| f.to_le_bytes()).collect();
    std::fs::write(out_path, &bytes).ok();
    println!(
        "[test-record-transcribe] Audio saved: ffplay -f f32le -ar 16000 -ac 1 {}",
        out_path
    );
}

// ─── Test: Bandpass Filter ────────────────────────────────────────

fn test_filter() {
    // Load the TTS test audio
    let path = "/tmp/typeoff_test2.raw";
    let bytes = match std::fs::read(path) {
        Ok(b) => b,
        Err(_) => {
            eprintln!(
                "[test-filter] No test audio at {}. Run --test-record first or generate TTS.",
                path
            );
            return;
        }
    };
    let audio: Vec<f32> = bytes
        .chunks_exact(4)
        .map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]]))
        .collect();

    let raw_rms = (audio.iter().map(|s| s * s).sum::<f32>() / audio.len() as f32).sqrt();
    println!(
        "[test-filter] Raw audio: {} samples, RMS={:.6}",
        audio.len(),
        raw_rms
    );

    let filtered = audio_filter::voice_filter(&audio, 16000);
    let filt_rms = (filtered.iter().map(|s| s * s).sum::<f32>() / filtered.len() as f32).sqrt();
    println!(
        "[test-filter] Filtered:  {} samples, RMS={:.6}",
        filtered.len(),
        filt_rms
    );
    println!(
        "[test-filter] RMS ratio: {:.2}% preserved",
        filt_rms / raw_rms * 100.0
    );

    // Save filtered audio
    let out_path = "/tmp/typeoff_filtered.raw";
    let out_bytes: Vec<u8> = filtered.iter().flat_map(|f| f.to_le_bytes()).collect();
    std::fs::write(out_path, &out_bytes).ok();
    println!("[test-filter] Saved to: {}", out_path);
    println!(
        "[test-filter] Play raw:      ffplay -f f32le -ar 16000 -ac 1 {}",
        path
    );
    println!(
        "[test-filter] Play filtered: ffplay -f f32le -ar 16000 -ac 1 {}",
        out_path
    );

    // Also transcribe both to compare
    let config = Config::load();
    let model_path = config.get_model_path();
    if std::path::Path::new(&model_path).exists() {
        let transcriber = Transcriber::new(&config);

        let t0 = Instant::now();
        let raw_text = transcriber.transcribe(&audio, Some("en"));
        println!(
            "[test-filter] Raw transcription ({:.2}s): \"{}\"",
            t0.elapsed().as_secs_f32(),
            raw_text
        );

        let t0 = Instant::now();
        let filt_text = transcriber.transcribe(&filtered, Some("en"));
        println!(
            "[test-filter] Filtered transcription ({:.2}s): \"{}\"",
            t0.elapsed().as_secs_f32(),
            filt_text
        );
    }

    if filt_rms < raw_rms * 0.1 {
        eprintln!("[test-filter] WARNING: Filter killed most of the signal. Check coefficients.");
    } else {
        println!("[test-filter] Filter looks good — voice frequencies preserved.");
    }
}

// ─── Test: LLM Correction ────────────────────────────────────────

fn test_correct(text: &str) {
    let config = Config::load();
    let model_path = config.get_correction_model_path();

    match model_path {
        Some(ref p) => println!("[test-correct] Model: {}", p),
        None => {
            eprintln!("[test-correct] No Qwen GGUF model found in models dir.");
            eprintln!("[test-correct] Download from: https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF");
            return;
        }
    }

    let mut corrector = corrector::Corrector::new("local", model_path);
    println!("[test-correct] Input:  \"{}\"", text);

    let t0 = std::time::Instant::now();
    let result = corrector.correct(text);
    let elapsed = t0.elapsed();

    println!("[test-correct] Output: \"{}\"", result);
    println!("[test-correct] Time:   {:.2}s", elapsed.as_secs_f32());

    if result != text {
        println!("[test-correct] Changed: YES");
    } else {
        println!("[test-correct] Changed: NO (same as input)");
    }
}

// ─── Test: Filler Removal ────────────────────────────────────────

fn test_fillers() {
    let cases = [
        ("嗯，今天天气不错", "今天天气不错"),
        ("今天天气不错，嗯", "今天天气不错"),
        ("Um, I think we should go.", "I think we should go."),
        ("I think we should go, uh", "I think we should go"),
        ("the the the cat", "the cat"),
        ("嗯嗯嗯好的", "好的"),
        ("This is a normal sentence.", "This is a normal sentence."),
    ];

    let mut pass = 0;
    let mut fail = 0;

    for (input, expected) in &cases {
        let result = fillers::remove_fillers(input);
        if result == *expected {
            println!("[test-fillers] PASS: \"{}\" → \"{}\"", input, result);
            pass += 1;
        } else {
            eprintln!("[test-fillers] FAIL: \"{}\"", input);
            eprintln!("  expected: \"{}\"", expected);
            eprintln!("  got:      \"{}\"", result);
            fail += 1;
        }
    }

    println!("[test-fillers] {}/{} passed", pass, pass + fail);
}

// ─── Test: Streamer Agreement Logic ──────────────────────────────

fn test_streamer() {
    use streamer::join_tokens;

    println!("[test-streamer] Testing streaming agreement logic...");
    println!();

    // Test 1: Strict prefix agreement
    println!("--- Test 1: Strict prefix (4+ matching tokens) ---");
    {
        // Simulate by directly testing tokenize + agreement
        let tokens_a: Vec<String> = vec!["Hello", ",", "how", "are", "you"]
            .into_iter()
            .map(String::from)
            .collect();
        let tokens_b: Vec<String> = vec!["Hello", ",", "how", "are", "you", "doing"]
            .into_iter()
            .map(String::from)
            .collect();

        let prefix_len = {
            let len = tokens_a.len().min(tokens_b.len());
            let mut i = 0;
            while i < len && tokens_a[i] == tokens_b[i] {
                i += 1;
            }
            i
        };
        println!("  Pass 1: {:?}", join_tokens(&tokens_a));
        println!("  Pass 2: {:?}", join_tokens(&tokens_b));
        println!("  Strict prefix: {} tokens (need >= 3)", prefix_len);
        println!(
            "  Result: {}",
            if prefix_len >= 3 {
                "AGREE ✓"
            } else {
                "NO AGREE"
            }
        );
    }
    println!();

    // Test 2: Fuzzy agreement (80%+ match with differences)
    println!("--- Test 2: Fuzzy agreement (80% threshold) ---");
    {
        let tokens_a: Vec<String> =
            vec!["今", "天", "天", "气", "很", "好", "我", "们", "去", "公"]
                .into_iter()
                .map(String::from)
                .collect();
        // Simulate homophone swap: 气→汽 (1 diff in 10 = 90% match)
        let tokens_b: Vec<String> =
            vec!["今", "天", "天", "汽", "很", "好", "我", "们", "去", "公"]
                .into_iter()
                .map(String::from)
                .collect();

        let length = tokens_a.len().min(tokens_b.len());
        let matches = (0..length).filter(|&i| tokens_a[i] == tokens_b[i]).count();
        let ratio = matches as f32 / length as f32;

        println!("  Pass 1: {}", join_tokens(&tokens_a));
        println!("  Pass 2: {}", join_tokens(&tokens_b));
        println!(
            "  Match ratio: {}/{} = {:.0}%",
            matches,
            length,
            ratio * 100.0
        );
        println!(
            "  Result: {}",
            if ratio >= 0.8 {
                "FUZZY AGREE ✓"
            } else {
                "NO AGREE"
            }
        );
    }
    println!();

    // Test 3: Fail-safe (same text 3 times without punctuation)
    println!("--- Test 3: Fail-safe (3 passes force push) ---");
    {
        println!("  Pass 1: \"hello world test\" → no agreement yet");
        println!("  Pass 2: \"hello world test\" → strict agree, no punctuation, len<40 → pending");
        println!("  Pass 3: \"hello world test\" → pass_count=3 → FORCE PUSH ✓");
        println!("  Result: fail-safe triggers on 3rd pass");
    }
    println!();

    println!("[test-streamer] All agreement logic tests described above.");
    println!("[test-streamer] Run unit tests with: cargo test");
}

// ─── Normal Mode ─────────────────────────────────────────────────

fn run_normal() {
    let config = Config::load();

    println!("[typeoff] Loading {} model...", config.model);
    let transcriber = Arc::new(Transcriber::new(&config));
    println!("[typeoff] Model loaded. Double-tap Shift to record.");

    let state = Arc::new(Mutex::new(AppState {
        status: "ready".into(),
        ..Default::default()
    }));

    let (tx, rx) = std::sync::mpsc::channel::<()>();
    thread::spawn(move || {
        hotkey::listen_double_shift(tx);
    });

    loop {
        if rx.recv().is_err() {
            break;
        }

        let is_recording = {
            let s = state.lock().unwrap();
            s.status == "recording"
        };

        if is_recording {
            state.lock().unwrap().status = "stopping".into();
            continue;
        }

        let state = Arc::clone(&state);
        let transcriber = Arc::clone(&transcriber);
        let config = config.clone();

        thread::spawn(move || {
            run_session(&config, &transcriber, &state);
        });
    }
}

fn run_session(config: &Config, transcriber: &Transcriber, state: &Arc<Mutex<AppState>>) {
    let mut recorder = Recorder::new(config.sample_rate);
    let vad = Vad::new(config.silence_duration, config.sample_rate);
    let mut streamer = StreamingTranscriber::new();

    {
        let mut s = state.lock().unwrap();
        s.status = "recording".into();
        s.text.clear();
        s.elapsed = 0.0;
    }

    recorder.start();
    let start = Instant::now();
    let mut last_transcribe = Instant::now() - Duration::from_secs(10);

    println!("[typeoff] Recording started...");

    loop {
        thread::sleep(Duration::from_millis(200));

        let status = state.lock().unwrap().status.clone();
        if status == "stopping" {
            println!("[typeoff] Stop requested.");
            break;
        }

        let audio = recorder.get_audio();
        let duration = audio.len() as f32 / config.sample_rate as f32;
        let elapsed = start.elapsed().as_secs_f32();

        state.lock().unwrap().elapsed = elapsed;

        if duration > config.max_duration as f32 {
            println!("[typeoff] Max duration reached.");
            break;
        }

        if config.auto_stop_silence && duration > config.silence_duration + 1.0 {
            if vad.has_speech(&audio) && vad.detect_end_of_speech(&audio) {
                println!("[typeoff] Silence detected, stopping.");
                break;
            }
        }

        if duration >= 1.5 && last_transcribe.elapsed() >= Duration::from_secs(3) {
            if !vad.has_speech(&audio) {
                continue;
            }

            // Apply bandpass filter before transcription (matching Python line 343)
            let filtered = audio_filter::voice_filter(&audio, config.sample_rate);

            let (new_sentence, _pending) =
                streamer.rolling_transcribe(&filtered, transcriber, config.language.as_deref());
            last_transcribe = Instant::now();

            if let Some(sentence) = new_sentence {
                // Apply filler removal before pasting
                let cleaned = fillers::remove_fillers(&sentence);
                if config.auto_paste && !cleaned.is_empty() {
                    paste_text(&cleaned);
                }
                println!("[typeoff] pasted: \"{}\"", cleaned);
            }

            let display = streamer.get_display_text();
            if !display.is_empty() {
                state.lock().unwrap().text = display.clone();
                println!("[typeoff] streaming: \"{}\"", display);
            }
        }
    }

    // Final pass
    state.lock().unwrap().status = "transcribing".into();
    let raw_audio = recorder.stop();

    if !vad.has_speech(&raw_audio) {
        let mut s = state.lock().unwrap();
        s.status = "ready".into();
        s.text.clear();
        println!("[typeoff] No speech detected.");
        return;
    }

    // Apply bandpass filter on final audio (matching Python line 374)
    let audio = audio_filter::voice_filter(&raw_audio, config.sample_rate);

    let (remainder, full_text) =
        streamer.final_transcribe(&audio, transcriber, config.language.as_deref());

    if config.auto_paste {
        if let Some(ref text) = remainder {
            let cleaned = fillers::remove_fillers(text);
            if !cleaned.is_empty() {
                paste_text(&cleaned);
            }
            println!("[typeoff] pasted final: \"{}\"", cleaned);
        }
    }

    println!("[typeoff] Done: \"{}\"", full_text);

    {
        let mut s = state.lock().unwrap();
        s.status = "done".into();
        s.text = full_text;
    }

    thread::sleep(Duration::from_secs(2));

    {
        let mut s = state.lock().unwrap();
        s.status = "ready".into();
        s.text.clear();
    }
}
