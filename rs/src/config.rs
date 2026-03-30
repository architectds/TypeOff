use serde::{Deserialize, Serialize};
use std::fs;
use std::path::PathBuf;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Config {
    #[serde(default = "default_model")]
    pub model: String,
    #[serde(default)]
    pub language: Option<String>,
    #[serde(default = "default_true")]
    pub auto_paste: bool,
    #[serde(default = "default_true")]
    pub auto_stop_silence: bool,
    #[serde(default = "default_silence_duration")]
    pub silence_duration: f32,
    #[serde(default = "default_max_duration")]
    pub max_duration: f32,
    #[serde(default = "default_sample_rate")]
    pub sample_rate: u32,
    #[serde(default)]
    pub model_path: Option<String>,
    #[serde(default = "default_use_gpu")]
    pub use_gpu: bool,
    #[serde(default = "default_correction_mode")]
    pub correction_mode: String,
    #[serde(default)]
    pub correction_model_path: Option<String>,
}

fn default_model() -> String {
    "small".into()
}
fn default_true() -> bool {
    true
}
fn default_silence_duration() -> f32 {
    3.0
}
fn default_max_duration() -> f32 {
    60.0
}
fn default_sample_rate() -> u32 {
    16000
}
fn default_correction_mode() -> String {
    "off".into()
}
fn default_use_gpu() -> bool {
    #[cfg(target_os = "macos")]
    {
        cfg!(feature = "metal") && cfg!(target_arch = "aarch64")
    }

    #[cfg(not(target_os = "macos"))]
    {
        cfg!(feature = "cuda")
    }
}

fn normalize_language(language: Option<String>) -> Option<String> {
    match language.as_deref().map(str::trim) {
        Some("") | Some("auto") => None,
        Some(value) => Some(value.to_string()),
        None => None,
    }
}

impl Default for Config {
    fn default() -> Self {
        Self {
            model: default_model(),
            language: None,
            auto_paste: true,
            auto_stop_silence: true,
            silence_duration: default_silence_duration(),
            max_duration: default_max_duration(),
            sample_rate: default_sample_rate(),
            model_path: None,
            use_gpu: default_use_gpu(),
            correction_mode: default_correction_mode(),
            correction_model_path: None,
        }
    }
}

impl Config {
    fn normalize(mut self) -> Self {
        self.language = normalize_language(self.language.take());
        self
    }

    pub fn config_path() -> PathBuf {
        let mut p = dirs::config_dir().unwrap_or_else(|| PathBuf::from("."));
        p.push("Typeoff");
        fs::create_dir_all(&p).ok();
        p.push("settings.json");
        p
    }

    pub fn load() -> Self {
        let path = Self::config_path();
        match fs::read_to_string(&path) {
            Ok(content) => serde_json::from_str::<Self>(&content)
                .unwrap_or_default()
                .normalize(),
            Err(_) => {
                let config = Self::default().normalize();
                config.save();
                config
            }
        }
    }

    pub fn save(&self) {
        let path = Self::config_path();
        if let Ok(json) = serde_json::to_string_pretty(&self.clone().normalize()) {
            fs::write(path, json).ok();
        }
    }

    pub fn effective_language(&self) -> Option<&str> {
        match self.language.as_deref().map(str::trim) {
            Some("") | Some("auto") | None => None,
            Some(language) => Some(language),
        }
    }

    pub fn models_dir() -> PathBuf {
        let config_dir = dirs::config_dir().unwrap_or_else(|| PathBuf::from("."));
        let dir_names = ["Typeoff", "TypeOff"];
        for name in &dir_names {
            let mut p = config_dir.clone();
            p.push(name);
            p.push("models");
            if p.exists() {
                return p;
            }
        }
        let mut p = config_dir;
        p.push("Typeoff");
        p.push("models");
        fs::create_dir_all(&p).ok();
        p
    }

    /// Get the GGML whisper model file path.
    pub fn get_model_path(&self) -> String {
        if let Some(ref p) = self.model_path {
            if std::path::Path::new(p).exists() {
                return p.clone();
            }
        }

        let config_dir = dirs::config_dir().unwrap_or_else(|| PathBuf::from("."));
        let dir_names = ["Typeoff", "TypeOff"];
        let file_patterns = [
            format!("ggml-{}.bin", self.model),
            format!("ggml-{}-q5_0.bin", self.model),
            format!("ggml-{}-q5_1.bin", self.model),
        ];

        for dir_name in &dir_names {
            for pattern in &file_patterns {
                let mut p = config_dir.clone();
                p.push(dir_name);
                p.push("models");
                p.push(pattern);
                if p.exists() {
                    println!("[typeoff] Found model: {}", p.display());
                    return p.to_string_lossy().into_owned();
                }
            }
        }

        let mut p = config_dir;
        p.push("Typeoff");
        p.push("models");
        fs::create_dir_all(&p).ok();
        p.push(format!("ggml-{}.bin", self.model));
        eprintln!("[typeoff] Model not found. Expected at: {}", p.display());
        p.to_string_lossy().into_owned()
    }

    /// Get the GGUF correction model path (Qwen).
    pub fn get_correction_model_path(&self) -> Option<String> {
        if let Some(ref p) = self.correction_model_path {
            if std::path::Path::new(p).exists() {
                return Some(p.clone());
            }
        }

        // Search for any qwen GGUF in models dir
        let models_dir = Self::models_dir();
        // Prefer higher quality quantizations first
        let patterns = [
            "qwen2.5-0.5b-instruct-q8_0.gguf",
            "qwen2.5-0.5b-instruct-q5_k_m.gguf",
            "qwen2.5-0.5b-instruct-q4_k_m.gguf",
            "Qwen2.5-0.5B-Instruct-Q8_0.gguf",
            "Qwen2.5-0.5B-Instruct-Q4_K_M.gguf",
        ];
        for pattern in &patterns {
            let p = models_dir.join(pattern);
            if p.exists() {
                println!("[typeoff] Found correction model: {}", p.display());
                return Some(p.to_string_lossy().into_owned());
            }
        }

        // Also try glob for any qwen gguf
        if let Ok(entries) = fs::read_dir(&models_dir) {
            for entry in entries.flatten() {
                let name = entry.file_name().to_string_lossy().to_lowercase();
                if name.contains("qwen") && name.ends_with(".gguf") {
                    println!(
                        "[typeoff] Found correction model: {}",
                        entry.path().display()
                    );
                    return Some(entry.path().to_string_lossy().into_owned());
                }
            }
        }

        None
    }
}
