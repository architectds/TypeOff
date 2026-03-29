use whisper_rs::{FullParams, SamplingStrategy, WhisperContext, WhisperContextParameters};

use crate::config::Config;

/// Suppress all whisper.cpp / ggml internal logging.
fn suppress_whisper_logging() {
    // Set GGML_LOG_LEVEL to suppress verbose output
    std::env::set_var("GGML_LOG_LEVEL", "0");
}

pub struct Transcriber {
    ctx: WhisperContext,
    language: Option<String>,
}

unsafe impl Send for Transcriber {}
unsafe impl Sync for Transcriber {}

impl Transcriber {
    pub fn new(config: &Config) -> Self {
        // Suppress verbose whisper.cpp output before loading model
        suppress_whisper_logging();

        let model_path = config.get_model_path();
        let mut ctx_params = WhisperContextParameters::default();

        // GPU detection per platform
        #[cfg(target_os = "macos")]
        {
            // Metal GPU only works on Apple Silicon (M-series).
            // AMD/Intel discrete GPUs produce garbled output.
            let is_apple_silicon = std::process::Command::new("sysctl")
                .args(["-n", "machdep.cpu.brand_string"])
                .output()
                .map(|o| String::from_utf8_lossy(&o.stdout).contains("Apple"))
                .unwrap_or(false);

            if is_apple_silicon {
                println!("[typeoff] Apple Silicon detected, using Metal GPU.");
            } else {
                println!("[typeoff] Non-Apple-Silicon Mac, using CPU.");
                ctx_params.use_gpu(false);
            }
        }

        #[cfg(target_os = "windows")]
        {
            // CUDA auto-detection: whisper.cpp will try CUDA if available,
            // fall back to CPU if no NVIDIA GPU found.
            // GPU is enabled by default — whisper.cpp handles the fallback.
            println!("[typeoff] Windows: GPU (CUDA) enabled if available, CPU fallback.");
        }

        #[cfg(target_os = "linux")]
        {
            println!("[typeoff] Linux: GPU (CUDA) enabled if available, CPU fallback.");
        }

        let ctx = WhisperContext::new_with_params(&model_path, ctx_params)
            .unwrap_or_else(|e| panic!("Failed to load model {}: {}", model_path, e));

        Self {
            ctx,
            language: config.language.clone(),
        }
    }

    pub fn transcribe(&self, audio: &[f32], language: Option<&str>) -> String {
        let mut params = FullParams::new(SamplingStrategy::Greedy { best_of: 1 });

        // Language: use explicit if provided, else auto-detect (None)
        let lang = language.or(self.language.as_deref());
        params.set_language(lang);

        params.set_print_special(false);
        params.set_print_progress(false);
        params.set_print_realtime(false);
        params.set_print_timestamps(false);
        params.set_single_segment(false);
        params.set_no_context(true);
        params.set_n_threads(4);

        // Suppress non-speech tokens to prevent [Music], [Applause] etc.
        params.set_suppress_nst(true);

        // Initial prompt guides punctuation and language mixing
        // Matching Python: "以下是一段语音转录。"
        params.set_initial_prompt("以下是一段语音转录。Hello, how are you?");

        let mut state = self.ctx.create_state().expect("Failed to create state");
        if let Err(e) = state.full(params, audio) {
            eprintln!("[typeoff] Transcription error: {}", e);
            return String::new();
        }

        let n = state.full_n_segments();
        let mut result = String::new();
        for i in 0..n {
            if let Some(seg) = state.get_segment(i) {
                if let Ok(text) = seg.to_str_lossy() {
                    let trimmed = text.trim();
                    // Skip hallucination tags like [Music], [Applause], etc.
                    if !trimmed.is_empty()
                        && !trimmed.starts_with('[')
                        && !trimmed.starts_with('(')
                    {
                        if !result.is_empty() {
                            result.push(' ');
                        }
                        result.push_str(trimmed);
                    }
                }
            }
        }
        result
    }
}
