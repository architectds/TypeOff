# Typeoff

Offline speech-to-text. Press a hotkey, speak, text appears in your active app. No cloud, no API keys, fully local.

![Rust](https://img.shields.io/badge/Rust-working-green)
![License](https://img.shields.io/badge/License-MIT-green)
![Platform](https://img.shields.io/badge/Platform-Mac%20%7C%20Windows%20%7C%20Linux-lightgrey)

## Download

Go to [Releases](https://github.com/architectds/typeoff/releases) and download for your platform:

| Installer | Platform | GPU | Notes |
|-----------|----------|-----|-------|
| `Typeoff-Mac-AppleSilicon.dmg` | Mac M1/M2/M3/M4 | Metal ✓ | Fast (~0.5s/pass) |
| `Typeoff-Mac-Intel.dmg` | Mac Intel | CPU | Slower (~3.5s/pass) |
| `Typeoff-Win-CPU.exe` | Windows (any) | CPU | Works everywhere |
| `Typeoff-Win-GPU.exe` | Windows + NVIDIA | CUDA 12+ | Fast, needs driver 535+ |

No Rust, no cmake, no compilation. Download, install, run.

The app downloads the Whisper model (~465MB) on first launch.

## How it works

1. Double-tap **Shift** to start recording
2. Speak — text streams in real-time
3. Confirmed sentences are **pasted into your active app** as you speak
4. Double-tap **Shift** again or wait for silence to stop

## Pipeline

```
Mic → Bandpass Filter → VAD → Whisper → Streaming Agreement → Filler Removal → Auto-Paste
      (50-3400Hz)      (RMS)  (small)   (fuzzy 80% match)    (嗯/uh/um/那个)   (Cmd+V/Ctrl+V)
```

Everything runs locally. ~500MB memory. No internet needed after model download.

## Features

- **Fully offline** — no cloud, no API keys, no data leaves your machine
- **Streaming flush** — sentences paste as you speak, not after you stop
- **GPU accelerated** — Metal (Apple Silicon), CUDA 12+ (NVIDIA), CPU fallback
- **Fuzzy agreement** — 80% token match confirms text, tolerates Whisper variance
- **Voice filter** — 50-3400Hz bandpass removes keyboard/HVAC/electronic noise
- **Filler removal** — strips "嗯", "那个", "uh", "um" automatically
- **CJK-aware** — per-character tokenization for Chinese/Japanese/Korean
- **Multilingual** — 99 languages via Whisper, auto-detect
- **System tray** — runs in background, double-click tray icon to show UI
- **Auto-start** — optional launch at login

### Streaming Algorithm

```
Pass 1: "今天天气很好"              → baseline
Pass 2: "今天天气很好，我们去公园"    → fuzzy agree (80%+) → LOCK "今天天气很好，" → paste
Pass 3 (new window): "我们去公园玩"  → continue...

Fail safe: after 3 passes without LOCK → push to last punctuation
```

## Build from Source (Developers)

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
cargo tauri dev          # ← The ONLY command you need
```

**IMPORTANT:** Do NOT run `cargo run` or `cargo build` — that builds the CLI binary separately and wastes time. Always use `cargo tauri dev`.

### Build installers

```bash
cd rs
cargo tauri build                # CPU build (Mac or Windows)
cargo tauri build --features cuda  # Windows GPU build (needs CUDA Toolkit 12+)
```

### CI/CD

GitHub Actions automatically builds all 4 installers on git tag:

```bash
git tag v0.2.0
git push --tags
# → Mac Intel .dmg, Mac Silicon .dmg, Win CPU .exe, Win GPU .exe
# → Uploaded to GitHub Releases
```

## Architecture

```
rs/
  src/
    lib.rs               — Pipeline module exports
    config.rs            — JSON settings, model path search
    recorder.rs          — Audio capture (cpal, 48kHz→16kHz resampling)
    audio_filter.rs      — Bandpass filter (50-3400Hz, biquad)
    vad.rs               — Voice activity detection (RMS energy)
    transcriber.rs       — Whisper inference (whisper-rs, Metal/CUDA/CPU)
    streamer.rs          — Streaming agreement (fuzzy 80% + fail-safe)
    fillers.rs           — Filler removal (Chinese + English + stutter)
    corrector.rs         — LLM correction (Qwen 0.5B via llama-cpp-2)
    hotkey.rs            — Double-shift detection (rdev)
    paster.rs            — Auto-paste (CGEvent on Mac, enigo on Win/Linux)
  src-tauri/
    src/lib.rs           — Tauri commands, system tray, session management
    tauri.conf.json      — Window config, permissions
  ui/
    index.html           — Webview UI (Catppuccin dark theme)
```

### Dependencies

| Component | Crate | Purpose |
|-----------|-------|---------|
| Whisper | `whisper-rs` 0.16 | whisper.cpp bindings, Metal/CUDA/CPU |
| LLM | `llama-cpp-2` 0.1 | Qwen 0.5B correction via llama.cpp |
| Audio | `cpal` 0.15 | CoreAudio / WASAPI / ALSA |
| Filter | `biquad` 0.4 | Bandpass 50-3400Hz |
| Hotkey | `rdev` (fufesou fork) | Double-shift, fixes macOS TSM crash |
| Clipboard | `arboard` 3 | Cross-platform clipboard |
| Paste | `core-graphics` 0.23 | CGEvent Cmd+V on macOS |
| UI | `tauri` 2.10 | Desktop app, system tray, webview |

## License

MIT
