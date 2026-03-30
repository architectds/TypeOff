/// Voice Activity Detection — RMS-based, only checks tail of audio.
pub struct Vad {
    silence_threshold: f32,
    silence_duration: f32,
    sample_rate: u32,
}

impl Vad {
    pub fn new(silence_duration: f32, sample_rate: u32) -> Self {
        Self {
            silence_threshold: 0.005,
            silence_duration,
            sample_rate,
        }
    }

    fn rms(chunk: &[f32]) -> f32 {
        if chunk.is_empty() {
            return 0.0;
        }
        let sum: f32 = chunk.iter().map(|s| s * s).sum();
        (sum / chunk.len() as f32).sqrt()
    }

    fn is_silence(&self, chunk: &[f32]) -> bool {
        Self::rms(chunk) < self.silence_threshold
    }

    /// Check if audio tail has enough silence to stop.
    pub fn detect_end_of_speech(&self, audio: &[f32]) -> bool {
        let silence_samples = (self.silence_duration * self.sample_rate as f32) as usize;
        if audio.len() < silence_samples {
            return false;
        }

        let tail = &audio[audio.len() - silence_samples..];
        let window = (0.5 * self.sample_rate as f32) as usize;

        for chunk in tail.chunks(window) {
            if !self.is_silence(chunk) {
                return false;
            }
        }
        true
    }

    /// Check if audio contains any speech.
    pub fn has_speech(&self, audio: &[f32]) -> bool {
        let window = (0.2 * self.sample_rate as f32) as usize;
        let needed = 2; // ~0.4s of speech
        let mut speech_windows = 0;

        // Only scan first 10s and last 10s
        let scan = (10.0 * self.sample_rate as f32) as usize;
        let regions: Vec<&[f32]> = if audio.len() > scan * 2 {
            vec![&audio[..scan], &audio[audio.len() - scan..]]
        } else {
            vec![audio]
        };

        for region in regions {
            for chunk in region.chunks(window) {
                if !self.is_silence(chunk) {
                    speech_windows += 1;
                    if speech_windows >= needed {
                        return true;
                    }
                }
            }
        }
        false
    }

    /// Check whether the recent audio tail still contains speech.
    pub fn has_recent_speech(&self, audio: &[f32], seconds: f32) -> bool {
        if audio.is_empty() {
            return false;
        }

        let tail_samples = ((seconds.max(0.0)) * self.sample_rate as f32) as usize;
        let start = audio.len().saturating_sub(tail_samples.max(1));
        !self.is_silence(&audio[start..])
    }
}
