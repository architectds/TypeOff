use whisper_rs::{FullParams, SamplingStrategy, WhisperContext, WhisperContextParameters};

use crate::config::Config;

fn suppress_whisper_logging() {
    std::env::set_var("GGML_LOG_LEVEL", "2");
}

pub struct Transcriber {
    ctx: WhisperContext,
    language: Option<String>,
}

unsafe impl Send for Transcriber {}

impl Transcriber {
    pub fn new(config: &Config) -> Self {
        suppress_whisper_logging();

        let model_path = config.get_model_path();
        let mut ctx_params = WhisperContextParameters::default();

        if config.use_gpu {
            #[cfg(target_os = "macos")]
            {
                if cfg!(target_arch = "aarch64") {
                    println!("[typeoff] GPU ON - Apple Silicon Metal.");
                } else {
                    println!("[typeoff] GPU requested but Intel Mac build uses CPU.");
                    ctx_params.use_gpu(false);
                }
            }

            #[cfg(not(target_os = "macos"))]
            {
                println!("[typeoff] GPU ON - CUDA if available, CPU fallback.");
            }
        } else {
            println!("[typeoff] GPU OFF - using CPU.");
            ctx_params.use_gpu(false);
        }

        let ctx = WhisperContext::new_with_params(&model_path, ctx_params)
            .unwrap_or_else(|e| panic!("Failed to load model {}: {}", model_path, e));

        Self {
            ctx,
            language: config.effective_language().map(str::to_string),
        }
    }

    pub fn transcribe(&self, audio: &[f32], language: Option<&str>) -> String {
        let mut params = FullParams::new(SamplingStrategy::Greedy { best_of: 1 });

        let lang = language.or(self.language.as_deref());
        params.set_language(lang);

        params.set_print_special(false);
        params.set_print_progress(false);
        params.set_print_realtime(false);
        params.set_print_timestamps(false);
        params.set_single_segment(false);
        params.set_no_context(true);
        params.set_n_threads(4);
        params.set_suppress_nst(true);
        params.set_initial_prompt(
            "Transcribe the spoken audio faithfully. Preserve the original language and punctuation.",
        );

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
                    if !trimmed.is_empty() && !trimmed.starts_with('[') && !trimmed.starts_with('(')
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
