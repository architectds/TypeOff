# Typeoff

Offline speech-to-text. Press a hotkey, speak, text appears in your active app. No cloud, no API keys, fully local.

![Rust](https://img.shields.io/badge/Rust-working-green)
![Python](https://img.shields.io/badge/Python-3.10+-blue)
![License](https://img.shields.io/badge/License-MIT-green)
![Platform](https://img.shields.io/badge/Platform-Mac%20%7C%20Windows%20%7C%20Linux-lightgrey)

## Project Structure

```
typeoff/
├── rs/        ← Rust version (primary, cross-platform, Tauri UI)
├── python/    ← Python version (reference implementation)
└── asset/     ← Shared assets (logo, icons)
```

## How it works

1. Double-tap **Shift** (configurable)
2. Speak — text streams in real-time
3. Confirmed sentences are pasted into your active app as you speak
4. When you stop, the remaining text is pasted

## Pipeline

```
Mic → Bandpass Filter → VAD → Whisper → Streaming Agreement → Filler Removal → LLM Correction → Paste
      (50-3400Hz)      (RMS)  (small)   (fuzzy 80% match)    (嗯/uh/um/那个)   (Qwen 0.5B)
```

Everything runs locally. ~1GB memory (Whisper 500MB + Qwen 500MB). Metal GPU on Apple Silicon, CUDA on Windows/Linux.

## Build & Run

### Prerequisites (one-time)

**Mac:**
```bash
brew install cmake
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
cargo install tauri-cli
```

**Windows:**
```powershell
winget install Microsoft.VisualStudio.2022.BuildTools --override "--add Microsoft.VisualStudio.Workload.VCTools"
winget install Rustlang.Rustup
winget install Kitware.CMake
cargo install tauri-cli
```

### Run (dev mode)

```bash
cd rs
cargo tauri dev          # ← This is the ONLY command you need
```

**IMPORTANT:** Do NOT run `cargo run` or `cargo build` directly — that builds the CLI binary separately and wastes time. Always use `cargo tauri dev` which builds only the Tauri app.

### Build installer (for distribution)

```bash
cd rs
cargo tauri build        # Produces .dmg (Mac) or .exe/.msi (Windows)
```

The app downloads the Whisper model on first launch — no manual model setup needed.

### Rust Dependencies

| Component | Crate | Purpose |
|-----------|-------|---------|
| Whisper inference | `whisper-rs` 0.16 | whisper.cpp, Metal/CUDA/CPU |
| LLM correction | `llama-cpp-2` 0.1 | Qwen 0.5B via llama.cpp |
| Audio capture | `cpal` 0.15 | CoreAudio/WASAPI/ALSA |
| Audio filter | `biquad` 0.4 | Bandpass 50-3400Hz |
| Hotkey | `rdev` (fufesou fork) | Double-shift detection |
| Clipboard | `arboard` 3 | Cross-platform clipboard |
| Paste sim | `enigo` 0.2 / osascript | Cmd+V (Mac) / Ctrl+V |
| Filler removal | `regex` 1 | Chinese + English fillers |
| Desktop UI | `tauri` 2 | Webview shell + system tray |

### Platform Support

| | Mac (Apple Silicon) | Mac (Intel) | Windows | Linux |
|---|---|---|---|---|
| Whisper | Metal GPU | CPU | CUDA / CPU | CUDA / CPU |
| LLM (Qwen) | Metal GPU | CPU | CUDA / CPU | CUDA / CPU |
| Audio | CoreAudio | CoreAudio | WASAPI | ALSA/Pulse |
| Hotkey | ✓ | ✓ | ✓ | X11 only |
| Paste | osascript | osascript | enigo | enigo |
| UI | WKWebView | WKWebView | WebView2 | WebKitGTK |

## Python Version (python/)

Reference implementation. Feature-complete with webview UI.

```bash
cd python
pip install -r requirements-win.txt
python typeoff.py
```

## Features

- **Fully offline** — no internet needed after model download
- **GPU accelerated** — Metal (Mac), CUDA (Win/Linux), CPU fallback
- **Streaming transcription** — see text as you speak, not after
- **Fuzzy LocalAgreement** — 80% token match confirms text, tolerates Whisper variance
- **Fail safe** — after 3 passes, force push to last punctuation
- **Voice bandpass filter** — 50-3400Hz, removes keyboard/HVAC/electronic noise
- **Auto-paste** — confirmed sentences paste directly into active app
- **CJK-aware** — per-character tokenization for Chinese/Japanese/Korean
- **Filler removal** — strips "嗯", "那个", "uh", "um" etc.
- **LLM correction** — Qwen2.5-0.5B fixes homophones (optional, via llama.cpp)
- **Multilingual** — 99 languages via Whisper, auto-detect
- **GPU accelerated** — Metal (Apple Silicon), CUDA (Win/Linux), auto-detect with CPU fallback

### Streaming Algorithm

```
Pass 1: "今天天气很好"              → baseline
Pass 2: "今天天气很好，我们去公园"    → fuzzy agree (80%+) → LOCK "今天天气很好，" → paste
Pass 3 (new window): "我们去公园玩"  → continue...

Fail safe: after 3 passes without LOCK → push to last punctuation
```

## Coming Soon

- **Tauri v2 UI** — webview shell + system tray + settings
- **LLM correction** — Qwen2.5-0.5B homophone fixes via llama.cpp
- **Model auto-download** — fetch on first run

## License

MIT
