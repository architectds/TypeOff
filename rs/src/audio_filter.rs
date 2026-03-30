/// Human voice bandpass filter — keep 50Hz-3400Hz, cut everything else.
///
/// Port of python/engine/audio_filter.py.
/// Uses cascaded biquad filters (highpass + lowpass) to approximate
/// a Butterworth bandpass filter.
use biquad::*;

const LOW_CUT: f32 = 50.0; // Hz — generous low end, catches all voice fundamentals
const HIGH_CUT: f32 = 3400.0; // Hz — upper harmonics for clarity, sibilance up to ~4kHz

/// Apply bandpass filter to keep only human voice frequencies.
///
/// Cascades a 2nd-order highpass at 50Hz with a 2nd-order lowpass at 3400Hz,
/// matching the Python Butterworth bandpass behavior.
pub fn voice_filter(audio: &[f32], sample_rate: u32) -> Vec<f32> {
    if audio.len() < 100 {
        return audio.to_vec();
    }

    let fs = sample_rate as f32;
    let fs_hz = fs.hz();

    // Highpass at 50Hz (removes HVAC rumble, traffic, electrical hum)
    let hp_coeffs =
        Coefficients::<f32>::from_params(Type::HighPass, fs_hz, LOW_CUT.hz(), Q_BUTTERWORTH_F32)
            .expect("Failed to create highpass filter");

    // Lowpass at 3400Hz (removes keyboard clicks, mouse clicks, hiss)
    let lp_coeffs =
        Coefficients::<f32>::from_params(Type::LowPass, fs_hz, HIGH_CUT.hz(), Q_BUTTERWORTH_F32)
            .expect("Failed to create lowpass filter");

    // Two cascaded stages for each (4th order total, close to Python's order-5)
    let mut hp1 = DirectForm2Transposed::<f32>::new(hp_coeffs);
    let mut hp2 = DirectForm2Transposed::<f32>::new(hp_coeffs);
    let mut lp1 = DirectForm2Transposed::<f32>::new(lp_coeffs);
    let mut lp2 = DirectForm2Transposed::<f32>::new(lp_coeffs);

    let mut output = Vec::with_capacity(audio.len());
    for &sample in audio {
        let s = hp1.run(sample);
        let s = hp2.run(s);
        let s = lp1.run(s);
        let s = lp2.run(s);
        output.push(s);
    }

    output
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_voice_filter_preserves_length() {
        let audio: Vec<f32> = (0..16000).map(|i| (i as f32 * 0.01).sin()).collect();
        let filtered = voice_filter(&audio, 16000);
        assert_eq!(audio.len(), filtered.len());
    }

    #[test]
    fn test_voice_filter_short_audio_passthrough() {
        let audio = vec![0.1, 0.2, 0.3];
        let filtered = voice_filter(&audio, 16000);
        assert_eq!(audio, filtered);
    }
}
