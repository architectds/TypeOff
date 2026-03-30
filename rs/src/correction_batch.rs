use std::time::{Duration, Instant};

pub const DEFAULT_MAX_SENTENCES: usize = 2;
pub const DEFAULT_MAX_CHARS: usize = 120;

pub struct CorrectionBatch {
    chunks: Vec<String>,
    char_count: usize,
    max_sentences: usize,
    max_chars: usize,
    last_update: Option<Instant>,
}

impl CorrectionBatch {
    pub fn new(max_sentences: usize, max_chars: usize) -> Self {
        Self {
            chunks: Vec::new(),
            char_count: 0,
            max_sentences,
            max_chars,
            last_update: None,
        }
    }

    pub fn push(&mut self, text: &str) -> bool {
        let trimmed = text.trim();
        if trimmed.is_empty() {
            return false;
        }

        self.char_count += trimmed.chars().count();
        self.chunks.push(trimmed.to_string());
        self.last_update = Some(Instant::now());
        true
    }

    pub fn is_empty(&self) -> bool {
        self.chunks.is_empty()
    }

    pub fn should_flush(&self) -> bool {
        self.chunks.len() >= self.max_sentences || self.char_count >= self.max_chars
    }

    pub fn should_flush_after_idle(&self, idle_for: Duration) -> bool {
        !self.is_empty()
            && self
                .last_update
                .is_some_and(|last_update| last_update.elapsed() >= idle_for)
    }

    pub fn take_text(&mut self) -> Option<String> {
        if self.chunks.is_empty() {
            return None;
        }

        let text = join_chunks(&self.chunks);
        self.chunks.clear();
        self.char_count = 0;
        self.last_update = None;
        Some(text)
    }
}

impl Default for CorrectionBatch {
    fn default() -> Self {
        Self::new(DEFAULT_MAX_SENTENCES, DEFAULT_MAX_CHARS)
    }
}

fn is_cjkish(c: char) -> bool {
    let cp = c as u32;
    (0x4E00..=0x9FFF).contains(&cp)
        || (0x3400..=0x4DBF).contains(&cp)
        || (0x3040..=0x309F).contains(&cp)
        || (0x30A0..=0x30FF).contains(&cp)
        || (0xAC00..=0xD7AF).contains(&cp)
        || matches!(c, '。' | '！' | '？' | '，' | '、' | '：' | '；')
}

fn join_chunks(chunks: &[String]) -> String {
    let mut result = String::new();

    for chunk in chunks {
        let trimmed = chunk.trim();
        if trimmed.is_empty() {
            continue;
        }

        if let (Some(prev), Some(next)) = (result.chars().last(), trimmed.chars().next()) {
            let prev_cjkish = is_cjkish(prev);
            let next_cjkish = is_cjkish(next);
            if !(prev_cjkish && next_cjkish) {
                result.push(' ');
            }
        }

        result.push_str(trimmed);
    }

    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn flushes_on_sentence_count() {
        let mut batch = CorrectionBatch::new(2, 120);
        batch.push("Hello world.");
        assert!(!batch.should_flush());
        batch.push("How are you?");
        assert!(batch.should_flush());
    }

    #[test]
    fn joins_english_with_space() {
        let mut batch = CorrectionBatch::default();
        batch.push("Hello world.");
        batch.push("How are you?");
        assert_eq!(batch.take_text().unwrap(), "Hello world. How are you?");
    }

    #[test]
    fn joins_cjk_without_space() {
        let mut batch = CorrectionBatch::default();
        batch.push("你好。");
        batch.push("我们走吧。");
        assert_eq!(batch.take_text().unwrap(), "你好。我们走吧。");
    }
}
