/// Streaming transcription — sentence-based sliding window + LocalAgreement.
///
/// Port of python/engine/streamer.py.
///
/// Strategy:
///   1. Record continuously, transcribe rolling buffer every N seconds
///   2. Word-level LocalAgreement: only trust words that match across 2 runs
///   3. When a complete sentence is confirmed → LOCK it, paste it, slide window
///   4. Re-transcribe only the audio after the locked sentence (~5-10s)
///   5. Final pass: re-transcribe last incomplete sentence for accuracy
use crate::transcriber::Transcriber;

/// Common Whisper hallucinations
const HALLUCINATIONS: &[&str] = &[
    "",
    "you",
    "thank you.",
    "thanks for watching!",
    "thanks for watching.",
    "subscribe",
    "bye.",
    "bye",
    "thank you",
    "you.",
    "the end.",
    "thanks for listening.",
    "see you next time.",
    "thank you for watching.",
    "...",
];

/// Check if char is CJK
fn is_cjk(c: char) -> bool {
    let cp = c as u32;
    (0x4E00..=0x9FFF).contains(&cp)
        || (0x3400..=0x4DBF).contains(&cp)
        || (0x3040..=0x309F).contains(&cp)
        || (0x30A0..=0x30FF).contains(&cp)
        || (0xAC00..=0xD7AF).contains(&cp)
}

/// CJK-aware tokenization (port of Python _tokenize)
fn tokenize(text: &str) -> Vec<String> {
    let mut tokens = Vec::new();
    let mut buf = String::new();
    for ch in text.chars() {
        if is_cjk(ch) {
            if !buf.is_empty() {
                tokens.push(std::mem::take(&mut buf));
            }
            tokens.push(ch.to_string());
        } else if ch.is_whitespace() {
            if !buf.is_empty() {
                tokens.push(std::mem::take(&mut buf));
            }
        } else {
            buf.push(ch);
        }
    }
    if !buf.is_empty() {
        tokens.push(buf);
    }
    tokens
}

/// Join tokens, no space between adjacent CJK (port of Python _join_tokens)
pub fn join_tokens(tokens: &[String]) -> String {
    if tokens.is_empty() {
        return String::new();
    }
    let mut result = tokens[0].clone();
    for i in 1..tokens.len() {
        let prev_cjk = tokens[i - 1].chars().last().map_or(false, is_cjk);
        let cur_cjk = tokens[i].chars().next().map_or(false, is_cjk);
        if !(prev_cjk && cur_cjk) {
            result.push(' ');
        }
        result.push_str(&tokens[i]);
    }
    result
}

/// Longest common prefix of two token lists (port of Python _common_prefix_words)
fn common_prefix_len(a: &[String], b: &[String]) -> usize {
    let len = a.len().min(b.len());
    for i in 0..len {
        if a[i] != b[i] {
            return i;
        }
    }
    len
}

/// Fuzzy agreement: if 80%+ tokens match positionally, return agreed tokens.
/// On mismatch, prefer tokens from words_b (latest run).
/// Port of Python _fuzzy_agree.
fn fuzzy_agree(words_a: &[String], words_b: &[String], threshold: f32) -> (Vec<String>, f32) {
    let length = words_a.len().min(words_b.len());
    if length == 0 {
        return (Vec::new(), 0.0);
    }

    let mut matches = 0;
    let mut agreed = Vec::with_capacity(length);
    for i in 0..length {
        if words_a[i] == words_b[i] {
            matches += 1;
        }
        // Always prefer latest run (words_b) on mismatch
        agreed.push(words_b[i].clone());
    }

    let ratio = matches as f32 / length as f32;
    if ratio >= threshold {
        (agreed, ratio)
    } else {
        (Vec::new(), ratio)
    }
}

/// Check if text ends with punctuation suitable for locking
fn has_lock_punct(text: &str) -> bool {
    text.trim_end()
        .ends_with(|c: char| ".!?。！？,，;；:：、".contains(c))
}

/// Split text into (complete_sentences, remainder) at last punctuation.
/// Port of Python _extract_complete_sentences.
fn extract_complete_sentences(text: &str) -> (String, String) {
    let chars: Vec<char> = text.chars().collect();
    for i in (0..chars.len()).rev() {
        if ".!?。！？,，;；:：、".contains(chars[i]) {
            let complete: String = chars[..=i].iter().collect();
            let remainder: String = chars[i + 1..].iter().collect();
            return (complete.trim().to_string(), remainder.trim().to_string());
        }
    }
    (String::new(), text.to_string())
}

pub struct StreamingTranscriber {
    prev_words: Vec<String>,
    confirmed_words: Vec<String>,
    locked_text: String,
    pending_text: String,
    pending_discard_samples: usize,
    window_pass_count: usize,
    max_passes: usize,
}

impl StreamingTranscriber {
    pub fn new() -> Self {
        Self {
            prev_words: Vec::new(),
            confirmed_words: Vec::new(),
            locked_text: String::new(),
            pending_text: String::new(),
            pending_discard_samples: 0,
            window_pass_count: 0,
            max_passes: 3,
        }
    }

    /// Run one rolling transcription pass with fuzzy agreement + fail safe.
    /// Returns (new_sentence, pending_text).
    /// Port of Python rolling_transcribe.
    pub fn rolling_transcribe(
        &mut self,
        window: &[f32],
        transcriber: &Transcriber,
        language: Option<&str>,
    ) -> (Option<String>, String) {
        if window.len() < 8000 {
            // < 0.5s
            return (None, self.pending_text.clone());
        }

        let text = transcriber.transcribe(window, language);

        // Filter hallucinations
        if HALLUCINATIONS.contains(&text.to_lowercase().trim()) {
            return (None, self.pending_text.clone());
        }

        let current_words = tokenize(&text);
        self.window_pass_count += 1;

        // --- Agreement logic (matching Python lines 180-193) ---
        let mut agreed_words: Vec<String> = Vec::new();

        if !self.prev_words.is_empty() {
            // Try strict prefix first (>= 3 tokens)
            let strict_len = common_prefix_len(&self.prev_words, &current_words);
            if strict_len >= 3 {
                agreed_words = self.prev_words[..strict_len].to_vec();
            } else {
                // Try fuzzy agreement (80% threshold)
                let (fuzzy, _ratio) = fuzzy_agree(&self.prev_words, &current_words, 0.8);
                if !fuzzy.is_empty() {
                    agreed_words = fuzzy;
                }
            }
        }

        self.prev_words = current_words.clone();

        // Update confirmed words
        if !agreed_words.is_empty() && agreed_words.len() > self.confirmed_words.len() {
            self.confirmed_words = agreed_words;
        }

        let confirmed_text = join_tokens(&self.confirmed_words);

        // --- Fail safe: force push after N passes on same window ---
        if self.window_pass_count >= self.max_passes {
            let full_text = join_tokens(&current_words);
            if !full_text.trim().is_empty() {
                let (complete, remainder) = extract_complete_sentences(&full_text);
                if !complete.is_empty() {
                    self.do_lock(&complete, &current_words, window.len(), &remainder);
                    return (Some(complete), self.pending_text.clone());
                } else {
                    // No punctuation at all — push everything as last resort
                    self.do_lock(&full_text, &current_words, window.len(), "");
                    return (Some(full_text), self.pending_text.clone());
                }
            }
        }

        // --- Normal lock: agreement + punctuation or length ---
        let mut new_sentence = None;

        if !confirmed_text.is_empty() {
            let (complete, remainder) = extract_complete_sentences(&confirmed_text);

            if !complete.is_empty() {
                new_sentence = Some(complete.clone());
                self.do_lock(&complete, &current_words, window.len(), &remainder);
            } else if confirmed_text.len() > 40 {
                new_sentence = Some(confirmed_text.clone());
                self.do_lock(&confirmed_text, &current_words, window.len(), "");
            } else {
                self.pending_text = confirmed_text;
            }
        } else {
            self.pending_text = join_tokens(&current_words);
        }

        (new_sentence, self.pending_text.clone())
    }

    /// Lock text, slide window, reset agreement state.
    /// Port of Python _do_lock.
    fn do_lock(
        &mut self,
        lock_text: &str,
        current_words: &[String],
        window_len: usize,
        remainder: &str,
    ) {
        self.locked_text.push_str(lock_text);
        self.pending_text = remainder.to_string();

        // Slide window
        if !current_words.is_empty() {
            let locked_count = tokenize(lock_text).len();
            let consumed = if remainder.is_empty() {
                window_len
            } else {
                ((locked_count as f32 / current_words.len() as f32) * window_len as f32) as usize
            };
            self.pending_discard_samples = consumed.min(window_len);
        }

        // Reset agreement state
        let remaining = if remainder.is_empty() {
            Vec::new()
        } else {
            tokenize(remainder)
        };
        self.prev_words = remaining.clone();
        self.confirmed_words = remaining;
        self.window_pass_count = 0;
    }

    /// Final pass on remaining audio after last locked sentence.
    /// Returns (final_remainder, full_text).
    /// Port of Python final_transcribe.
    pub fn final_transcribe(
        &mut self,
        window: &[f32],
        transcriber: &Transcriber,
        language: Option<&str>,
    ) -> (Option<String>, String) {
        if window.len() < 4800 {
            // < 0.3s
            return (None, self.locked_text.clone());
        }

        let text = transcriber.transcribe(window, language);
        if HALLUCINATIONS.contains(&text.to_lowercase().trim()) {
            return (None, self.locked_text.clone());
        }

        let remainder = text.trim().to_string();
        let mut full = self.locked_text.clone();
        if !remainder.is_empty() {
            if !full.is_empty() {
                full.push(' ');
            }
            full.push_str(&remainder);
        }

        (
            if remainder.is_empty() {
                None
            } else {
                Some(remainder)
            },
            full,
        )
    }

    /// Get full display text (locked + raw current transcription)
    pub fn get_display_text(&self) -> String {
        let raw = join_tokens(&self.prev_words);
        if raw.is_empty() {
            format!("{}{}", self.locked_text, self.pending_text)
        } else {
            format!("{}{}", self.locked_text, raw)
        }
    }

    pub fn confirmed_text(&self) -> String {
        self.locked_text.clone()
    }

    pub fn pending_display_text(&self) -> String {
        let raw = join_tokens(&self.prev_words);
        if raw.is_empty() {
            self.pending_text.clone()
        } else {
            raw
        }
    }

    pub fn take_pending_discard_samples(&mut self) -> usize {
        let discard = self.pending_discard_samples;
        self.pending_discard_samples = 0;
        discard
    }

    pub fn reset(&mut self) {
        self.prev_words.clear();
        self.confirmed_words.clear();
        self.locked_text.clear();
        self.pending_text.clear();
        self.pending_discard_samples = 0;
        self.window_pass_count = 0;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_tokenize_cjk() {
        let tokens = tokenize("今天weather很好");
        assert_eq!(tokens, vec!["今", "天", "weather", "很", "好"]);
    }

    #[test]
    fn test_tokenize_english() {
        let tokens = tokenize("hello world test");
        assert_eq!(tokens, vec!["hello", "world", "test"]);
    }

    #[test]
    fn test_join_tokens_cjk() {
        let tokens: Vec<String> = vec!["今", "天", "weather", "很", "好"]
            .into_iter()
            .map(String::from)
            .collect();
        assert_eq!(join_tokens(&tokens), "今天 weather 很好");
    }

    #[test]
    fn test_fuzzy_agree_exact() {
        let a: Vec<String> = vec!["hello", "world", "test"]
            .into_iter()
            .map(String::from)
            .collect();
        let b = a.clone();
        let (agreed, ratio) = fuzzy_agree(&a, &b, 0.8);
        assert_eq!(agreed.len(), 3);
        assert_eq!(ratio, 1.0);
    }

    #[test]
    fn test_fuzzy_agree_one_diff() {
        let a: Vec<String> = vec!["hello", "world", "test", "here", "now"]
            .into_iter()
            .map(String::from)
            .collect();
        let b: Vec<String> = vec!["hello", "word", "test", "here", "now"]
            .into_iter()
            .map(String::from)
            .collect();
        let (agreed, ratio) = fuzzy_agree(&a, &b, 0.8);
        assert_eq!(agreed.len(), 5); // 4/5 = 80% >= threshold
        assert_eq!(ratio, 0.8);
        assert_eq!(agreed[1], "word"); // prefers latest (b)
    }

    #[test]
    fn test_fuzzy_agree_below_threshold() {
        let a: Vec<String> = vec!["a", "b", "c"].into_iter().map(String::from).collect();
        let b: Vec<String> = vec!["x", "y", "z"].into_iter().map(String::from).collect();
        let (agreed, _) = fuzzy_agree(&a, &b, 0.8);
        assert!(agreed.is_empty());
    }

    #[test]
    fn test_extract_complete_sentences() {
        let (complete, remainder) = extract_complete_sentences("Hello, world. How are you");
        assert_eq!(complete, "Hello, world.");
        assert_eq!(remainder, "How are you");
    }

    #[test]
    fn test_extract_no_punctuation() {
        let (complete, remainder) = extract_complete_sentences("Hello world");
        assert_eq!(complete, "");
        assert_eq!(remainder, "Hello world");
    }
}
