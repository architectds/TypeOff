/// Post-processing: remove filler words and collapse stutters.
///
/// Port of python/engine/fillers.py.
use regex::Regex;
use std::sync::LazyLock;

// --- Filler word lists ---

const CHINESE_FILLERS: &[&str] = &["那个", "就是", "然后", "这个", "对吧", "那么", "嗯", "啊"];
const ENGLISH_MULTI_FILLERS: &[&str] = &["uh huh", "you know", "i mean"];
const ENGLISH_SINGLE_FILLERS: &[&str] = &["uh", "um", "like", "so", "right"];

// --- CJK helpers ---

fn is_cjk(c: char) -> bool {
    let cp = c as u32;
    (0x4E00..=0x9FFF).contains(&cp)
        || (0x3400..=0x4DBF).contains(&cp)
        || (0x3040..=0x309F).contains(&cp)
        || (0x30A0..=0x30FF).contains(&cp)
        || (0xAC00..=0xD7AF).contains(&cp)
        || (0xFF00..=0xFFEF).contains(&cp)
}

fn is_cjk_text(text: &str) -> bool {
    if text.is_empty() {
        return false;
    }
    let cjk_count = text.chars().filter(|c| is_cjk(*c)).count();
    let total = text.chars().count();
    cjk_count as f32 > total as f32 * 0.3
}

// --- Chinese filler removal ---

fn remove_chinese_fillers(text: &str) -> String {
    let mut result = text.to_string();
    // Process longer fillers first to avoid partial matches
    for filler in CHINESE_FILLERS {
        let escaped = regex::escape(filler);
        // Remove filler at start of text (optionally followed by comma/space)
        let re = Regex::new(&format!(r"^{}[,，、\s]*", escaped)).unwrap();
        result = re.replace(&result, "").to_string();
        // Remove filler at end of text (optionally preceded by comma/space)
        let re = Regex::new(&format!(r"[,，、\s]*{}$", escaped)).unwrap();
        result = re.replace(&result, "").to_string();
        // Remove filler between punctuation/sentence boundaries
        let re = Regex::new(&format!(r"([。！？,，;；:：、])\s*{}\s*", escaped)).unwrap();
        result = re.replace_all(&result, "$1").to_string();
        // Remove filler followed by comma (standalone usage mid-sentence)
        let re = Regex::new(&format!(r"{}[,，、]\s*", escaped)).unwrap();
        result = re.replace_all(&result, "").to_string();
    }
    result.trim().to_string()
}

// --- English filler removal ---

fn remove_english_fillers(text: &str) -> String {
    let mut result = text.to_string();

    // Handle multi-word fillers first
    for filler in ENGLISH_MULTI_FILLERS {
        let escaped = regex::escape(filler);
        // At start of text
        let re = Regex::new(&format!(r"(?i)^{}[,;]?\s*", escaped)).unwrap();
        result = re.replace(&result, "").to_string();
        // At end of text
        let re = Regex::new(&format!(r"(?i)[,;]?\s*{}[.!?]?\s*$", escaped)).unwrap();
        result = re.replace(&result, "").to_string();
        // Between commas / after punctuation
        let re = Regex::new(&format!(r"(?i)([.!?,;])\s*{}\s*([,;]?\s*)", escaped)).unwrap();
        result = re.replace_all(&result, "$1 ").to_string();
        // Comma-delimited standalone
        let re = Regex::new(&format!(r"(?i),\s*{}\s*,", escaped)).unwrap();
        result = re.replace_all(&result, ",").to_string();
    }

    // Single-word fillers (whole words only via \b)
    for filler in ENGLISH_SINGLE_FILLERS {
        let escaped = regex::escape(filler);
        // At start of text
        let re = Regex::new(&format!(r"(?i)^\b{}\b[,;]?\s*", escaped)).unwrap();
        result = re.replace(&result, "").to_string();
        // At end of text
        let re = Regex::new(&format!(r"(?i)[,;]?\s*\b{}\b[.!?]?\s*$", escaped)).unwrap();
        result = re.replace(&result, "").to_string();
        // After sentence-ending punctuation
        let re = Regex::new(&format!(r"(?i)([.!?])\s*\b{}\b[,;]?\s+", escaped)).unwrap();
        result = re.replace_all(&result, "$1 ").to_string();
        // Comma-separated standalone
        let re = Regex::new(&format!(r"(?i),\s*\b{}\b\s*,", escaped)).unwrap();
        result = re.replace_all(&result, ",").to_string();
    }

    // Clean up multiple spaces
    static MULTI_SPACE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"  +").unwrap());
    result = MULTI_SPACE.replace_all(&result, " ").to_string();
    result.trim().to_string()
}

// --- Stutter collapse ---

fn collapse_stutters(text: &str) -> String {
    // CJK character repetition (e.g., 嗯嗯嗯 -> 嗯)
    // Rust regex doesn't support backreferences, so we do it char-by-char
    let mut result = String::new();
    let chars: Vec<char> = text.chars().collect();
    let mut i = 0;
    while i < chars.len() {
        let ch = chars[i];
        if is_cjk(ch) {
            // Count consecutive repeats of this CJK char
            let mut count = 1;
            while i + count < chars.len() && chars[i + count] == ch {
                count += 1;
            }
            // Keep only 1 if repeated 3+ times
            if count >= 3 {
                result.push(ch);
            } else {
                for _ in 0..count {
                    result.push(ch);
                }
            }
            i += count;
        } else {
            result.push(ch);
            i += 1;
        }
    }

    // Word-level repetition (e.g., "the the the" -> "the")
    let words: Vec<&str> = result.split_whitespace().collect();
    if words.len() < 3 {
        return result;
    }

    let mut output: Vec<&str> = Vec::new();
    let mut j = 0;
    while j < words.len() {
        let word = words[j];
        let mut count = 1;
        while j + count < words.len() && words[j + count].eq_ignore_ascii_case(word) {
            count += 1;
        }
        if count >= 3 {
            output.push(word);
        } else {
            for k in 0..count {
                output.push(words[j + k]);
            }
        }
        j += count;
    }

    output.join(" ")
}

// --- Public API ---

/// Remove filler words and collapse stutters from transcription output.
pub fn remove_fillers(text: &str) -> String {
    if text.is_empty() || text.trim().is_empty() {
        return text.to_string();
    }

    let mut result = text.trim().to_string();

    // Collapse stutters first so "嗯嗯嗯好的" → "嗯好的" before filler removal
    result = collapse_stutters(&result);

    if is_cjk_text(&result) {
        result = remove_chinese_fillers(&result);
    } else {
        result = remove_english_fillers(&result);
    }

    // Final cleanup: remove leading/trailing punctuation artifacts
    static LEADING_PUNCT: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r"^[,，、;；\s]+").unwrap());
    static TRAILING_PUNCT: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r"[,，、;；\s]+$").unwrap());

    result = LEADING_PUNCT.replace(&result, "").to_string();
    result = TRAILING_PUNCT.replace(&result, "").to_string();

    result.trim().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_chinese_filler_start() {
        assert_eq!(remove_fillers("嗯，今天天气不错"), "今天天气不错");
    }

    #[test]
    fn test_chinese_filler_end() {
        assert_eq!(remove_fillers("今天天气不错，嗯"), "今天天气不错");
    }

    #[test]
    fn test_english_filler_start() {
        assert_eq!(
            remove_fillers("Um, I think we should go."),
            "I think we should go."
        );
    }

    #[test]
    fn test_english_filler_end() {
        assert_eq!(
            remove_fillers("I think we should go, uh"),
            "I think we should go"
        );
    }

    #[test]
    fn test_word_stutter() {
        assert_eq!(remove_fillers("the the the cat"), "the cat");
    }

    #[test]
    fn test_cjk_stutter() {
        assert_eq!(remove_fillers("嗯嗯嗯好的"), "好的");
    }

    #[test]
    fn test_no_fillers() {
        assert_eq!(
            remove_fillers("This is a normal sentence."),
            "This is a normal sentence."
        );
    }

    #[test]
    fn test_empty() {
        assert_eq!(remove_fillers(""), "");
        assert_eq!(remove_fillers("  "), "  ");
    }
}
