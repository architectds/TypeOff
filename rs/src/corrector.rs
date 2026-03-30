#[cfg(feature = "local-correction")]
mod enabled {
    use llama_cpp_2::context::params::LlamaContextParams;
    use llama_cpp_2::llama_backend::LlamaBackend;
    use llama_cpp_2::llama_batch::LlamaBatch;
    use llama_cpp_2::model::params::LlamaModelParams;
    use llama_cpp_2::model::{AddBos, LlamaChatMessage, LlamaModel};
    use llama_cpp_2::sampling::LlamaSampler;

    const SYSTEM_PROMPT: &str = "\
You are a speech transcription correction assistant. \
Only fix obvious homophone or phonetic mistakes. \
Preserve the original meaning, wording, style, language, and punctuation. \
If the text is already correct, return it unchanged. \
Return only the corrected text.";

    pub struct Corrector {
        backend: Option<LlamaBackend>,
        model: Option<LlamaModel>,
        enabled: bool,
        model_path: String,
    }

    impl Corrector {
        pub fn new(correction_mode: &str, model_path: Option<String>) -> Self {
            let enabled = correction_mode == "local"
                && model_path.as_deref().is_some_and(|path| !path.is_empty());
            Self {
                backend: None,
                model: None,
                enabled,
                model_path: model_path.unwrap_or_default(),
            }
        }

        pub fn is_enabled(&self) -> bool {
            self.enabled
        }

        fn ensure_loaded(&mut self) -> bool {
            if self.model.is_some() {
                return true;
            }
            if !self.enabled || self.model_path.is_empty() {
                return false;
            }
            if !std::path::Path::new(&self.model_path).exists() {
                eprintln!("[corrector] Model not found: {}", self.model_path);
                self.enabled = false;
                return false;
            }

            println!("[corrector] Loading model: {}", self.model_path);

            let backend = match LlamaBackend::init() {
                Ok(backend) => backend,
                Err(error) => {
                    eprintln!("[corrector] Failed to init backend: {:?}", error);
                    self.enabled = false;
                    return false;
                }
            };

            let mut params = LlamaModelParams::default();

            #[cfg(target_os = "macos")]
            {
                if !cfg!(target_arch = "aarch64") {
                    println!("[corrector] Intel Mac build, using CPU.");
                    params = params.with_n_gpu_layers(0);
                }
            }

            let model = match LlamaModel::load_from_file(&backend, &self.model_path, &params) {
                Ok(model) => model,
                Err(error) => {
                    eprintln!("[corrector] Failed to load model: {:?}", error);
                    self.enabled = false;
                    return false;
                }
            };

            println!("[corrector] Model loaded.");
            self.backend = Some(backend);
            self.model = Some(model);
            true
        }

        pub fn correct(&mut self, text: &str) -> String {
            if !self.enabled || text.is_empty() || text.trim().is_empty() {
                return text.to_string();
            }
            if !self.ensure_loaded() {
                return text.to_string();
            }

            let model = self.model.as_ref().unwrap();
            let backend = self.backend.as_ref().unwrap();

            let messages = match (
                LlamaChatMessage::new("system".into(), SYSTEM_PROMPT.into()),
                LlamaChatMessage::new("user".into(), text.into()),
            ) {
                (Ok(system), Ok(user)) => vec![system, user],
                _ => return text.to_string(),
            };

            let prompt = match model.chat_template(None) {
                Ok(template) => match model.apply_chat_template(&template, &messages, true) {
                    Ok(prompt) => prompt,
                    Err(error) => {
                        eprintln!("[corrector] Chat template error: {:?}", error);
                        return text.to_string();
                    }
                },
                Err(_) => format!(
                    "<|im_start|>system\n{}<|im_end|>\n<|im_start|>user\n{}<|im_end|>\n<|im_start|>assistant\n",
                    SYSTEM_PROMPT, text
                ),
            };

            let ctx_params =
                LlamaContextParams::default().with_n_ctx(std::num::NonZeroU32::new(512));
            let mut ctx = match model.new_context(backend, ctx_params) {
                Ok(context) => context,
                Err(error) => {
                    eprintln!("[corrector] Context error: {:?}", error);
                    return text.to_string();
                }
            };

            let tokens = match model.str_to_token(&prompt, AddBos::Never) {
                Ok(tokens) => tokens,
                Err(error) => {
                    eprintln!("[corrector] Tokenize error: {:?}", error);
                    return text.to_string();
                }
            };

            let mut batch = LlamaBatch::new(512, 1);
            for (index, &token) in tokens.iter().enumerate() {
                let is_last = index == tokens.len() - 1;
                if batch.add(token, index as i32, &[0], is_last).is_err() {
                    return text.to_string();
                }
            }
            if ctx.decode(&mut batch).is_err() {
                return text.to_string();
            }

            let mut sampler = LlamaSampler::chain_simple([LlamaSampler::greedy()]);
            let max_new_tokens = text.len() + 50;
            let mut result_tokens = Vec::new();
            let mut n_cur = tokens.len() as i32;

            for _ in 0..max_new_tokens {
                let token = sampler.sample(&ctx, batch.n_tokens() - 1);
                sampler.accept(token);

                if model.is_eog_token(token) {
                    break;
                }

                result_tokens.push(token);

                batch.clear();
                if batch.add(token, n_cur, &[0], true).is_err() {
                    break;
                }
                n_cur += 1;

                if ctx.decode(&mut batch).is_err() {
                    break;
                }
            }

            let mut result_bytes = Vec::new();
            for &token in &result_tokens {
                if let Ok(bytes) = model.token_to_piece_bytes(token, 32, false, None) {
                    result_bytes.extend_from_slice(&bytes);
                }
            }
            let result = String::from_utf8_lossy(&result_bytes).trim().to_string();

            if result.is_empty() {
                return text.to_string();
            }

            let len_ratio = result.chars().count() as f32 / text.chars().count() as f32;
            if !(0.5..=1.5).contains(&len_ratio) {
                eprintln!(
                    "[corrector] Rejected (length {:.0}%): \"{}\" -> \"{}\"",
                    len_ratio * 100.0,
                    text,
                    result
                );
                return text.to_string();
            }

            if result != text {
                println!("[corrector] \"{}\" -> \"{}\"", text, result);
            }

            result
        }
    }
}

#[cfg(not(feature = "local-correction"))]
mod disabled {
    pub struct Corrector {
        enabled: bool,
    }

    impl Corrector {
        pub fn new(_correction_mode: &str, _model_path: Option<String>) -> Self {
            Self { enabled: false }
        }

        pub fn is_enabled(&self) -> bool {
            self.enabled
        }

        pub fn correct(&mut self, text: &str) -> String {
            text.to_string()
        }
    }
}

#[cfg(not(feature = "local-correction"))]
pub use disabled::Corrector;
#[cfg(feature = "local-correction")]
pub use enabled::Corrector;
