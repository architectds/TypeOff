use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::SampleFormat;
use std::sync::{Arc, Mutex};

const COMPACT_THRESHOLD_SAMPLES: usize = 32_000;

#[derive(Default)]
struct AudioBuffer {
    data: Vec<f32>,
    start: usize,
}

impl AudioBuffer {
    fn with_capacity(capacity: usize) -> Self {
        Self {
            data: Vec::with_capacity(capacity),
            start: 0,
        }
    }

    fn len(&self) -> usize {
        self.data.len().saturating_sub(self.start)
    }

    fn as_slice(&self) -> &[f32] {
        &self.data[self.start..]
    }

    fn clear(&mut self) {
        self.data.clear();
        self.start = 0;
    }

    fn append_capped(&mut self, samples: &[f32], max_samples: usize) {
        if samples.is_empty() {
            return;
        }

        let remaining = max_samples.saturating_sub(self.len());
        if remaining == 0 {
            return;
        }

        let samples = if samples.len() > remaining {
            &samples[..remaining]
        } else {
            samples
        };

        self.compact_if_needed(samples.len());
        self.data.extend_from_slice(samples);
    }

    fn snapshot(&self) -> Vec<f32> {
        self.as_slice().to_vec()
    }

    fn snapshot_tail(&self, tail_samples: usize) -> Vec<f32> {
        let audio = self.as_slice();
        let start = audio.len().saturating_sub(tail_samples);
        audio[start..].to_vec()
    }

    fn discard_front(&mut self, samples: usize) {
        if samples == 0 {
            return;
        }

        let discard = samples.min(self.len());
        self.start += discard;

        if self.start >= self.data.len() {
            self.clear();
        } else {
            self.compact_if_needed(0);
        }
    }

    fn compact_if_needed(&mut self, incoming: usize) {
        if self.start == 0 {
            return;
        }

        let should_compact = self.start >= COMPACT_THRESHOLD_SAMPLES
            || self.start * 2 >= self.data.len()
            || self.data.len() + incoming > self.data.capacity();

        if should_compact {
            self.data.drain(..self.start);
            self.start = 0;
        }
    }
}

type SharedAudioBuffer = Arc<Mutex<AudioBuffer>>;

pub struct Recorder {
    target_sample_rate: u32,
    max_samples: usize,
    buffer: SharedAudioBuffer,
    stream: Option<cpal::Stream>,
}

fn append_audio(buffer: &SharedAudioBuffer, samples: &[f32], max_samples: usize) {
    if samples.is_empty() {
        return;
    }
    buffer.lock().unwrap().append_capped(samples, max_samples);
}

fn ensure_capacity(buf: &mut Vec<f32>, desired: usize) {
    let capacity = buf.capacity();
    if capacity < desired {
        buf.reserve(desired - capacity);
    }
}

fn mix_i16_to_mono(input: &[i16], channels: usize, mono: &mut Vec<f32>) {
    mono.clear();
    ensure_capacity(mono, input.len() / channels.max(1));

    if channels <= 1 {
        mono.extend(input.iter().map(|&sample| sample as f32 / i16::MAX as f32));
        return;
    }

    for frame in input.chunks(channels) {
        let sum: f32 = frame
            .iter()
            .map(|&sample| sample as f32 / i16::MAX as f32)
            .sum();
        mono.push(sum / channels as f32);
    }
}

fn mix_u16_to_mono(input: &[u16], channels: usize, mono: &mut Vec<f32>) {
    mono.clear();
    ensure_capacity(mono, input.len() / channels.max(1));

    if channels <= 1 {
        mono.extend(
            input
                .iter()
                .map(|&sample| (sample as f32 / u16::MAX as f32) * 2.0 - 1.0),
        );
        return;
    }

    for frame in input.chunks(channels) {
        let sum: f32 = frame
            .iter()
            .map(|&sample| (sample as f32 / u16::MAX as f32) * 2.0 - 1.0)
            .sum();
        mono.push(sum / channels as f32);
    }
}

fn mix_f32_to_mono(input: &[f32], channels: usize, mono: &mut Vec<f32>) {
    mono.clear();
    ensure_capacity(mono, input.len() / channels.max(1));

    if channels <= 1 {
        mono.extend_from_slice(input);
        return;
    }

    for frame in input.chunks(channels) {
        let sum: f32 = frame.iter().copied().sum();
        mono.push(sum / channels as f32);
    }
}

fn resample_into(mono: &[f32], resample_ratio: f64, out: &mut Vec<f32>) {
    out.clear();
    let out_len = (mono.len() as f64 * resample_ratio) as usize;
    ensure_capacity(out, out_len);

    for i in 0..out_len {
        let src_idx = i as f64 / resample_ratio;
        let idx = src_idx as usize;
        let frac = (src_idx - idx as f64) as f32;
        let s0 = mono.get(idx).copied().unwrap_or(0.0);
        let s1 = mono.get(idx + 1).copied().unwrap_or(s0);
        out.push(s0 + (s1 - s0) * frac);
    }
}

impl Recorder {
    pub fn new(target_sample_rate: u32, max_duration: f32) -> Self {
        let headroom_seconds = 5.0;
        let max_samples =
            ((max_duration + headroom_seconds).ceil() as usize) * target_sample_rate as usize;

        Self {
            target_sample_rate,
            max_samples,
            buffer: Arc::new(Mutex::new(AudioBuffer::with_capacity(max_samples))),
            stream: None,
        }
    }

    pub fn start(&mut self) {
        {
            let mut buffer = self.buffer.lock().unwrap();
            buffer.clear();
        }

        let host = cpal::default_host();
        let device = host.default_input_device().expect("No input device found");

        println!("[typeoff] Audio device: {:?}", device.name());

        let supported = device
            .default_input_config()
            .expect("No default input config");

        let sample_format = supported.sample_format();
        let device_sr = supported.sample_rate().0;
        let channels = supported.channels() as usize;
        let target_sr = self.target_sample_rate;

        println!(
            "[typeoff] Device: {}Hz, {}ch, {:?} -> resampling to {}Hz",
            device_sr, channels, sample_format, target_sr
        );

        let config = cpal::StreamConfig {
            channels: supported.channels(),
            sample_rate: supported.sample_rate(),
            buffer_size: cpal::BufferSize::Default,
        };

        let buffer = Arc::clone(&self.buffer);
        let max_samples = self.max_samples;
        let resample_ratio = target_sr as f64 / device_sr as f64;

        let stream = match sample_format {
            SampleFormat::I16 => {
                let buffer = Arc::clone(&buffer);
                let mut mono = Vec::new();
                let mut resampled = Vec::new();
                device
                    .build_input_stream(
                        &config,
                        move |data: &[i16], _: &cpal::InputCallbackInfo| {
                            mix_i16_to_mono(data, channels, &mut mono);
                            if device_sr != target_sr {
                                resample_into(&mono, resample_ratio, &mut resampled);
                                append_audio(&buffer, &resampled, max_samples);
                            } else {
                                append_audio(&buffer, &mono, max_samples);
                            }
                        },
                        |err| eprintln!("[typeoff] Audio error: {}", err),
                        None,
                    )
                    .expect("Failed to build i16 input stream")
            }
            SampleFormat::U16 => {
                let buffer = Arc::clone(&buffer);
                let mut mono = Vec::new();
                let mut resampled = Vec::new();
                device
                    .build_input_stream(
                        &config,
                        move |data: &[u16], _: &cpal::InputCallbackInfo| {
                            mix_u16_to_mono(data, channels, &mut mono);
                            if device_sr != target_sr {
                                resample_into(&mono, resample_ratio, &mut resampled);
                                append_audio(&buffer, &resampled, max_samples);
                            } else {
                                append_audio(&buffer, &mono, max_samples);
                            }
                        },
                        |err| eprintln!("[typeoff] Audio error: {}", err),
                        None,
                    )
                    .expect("Failed to build u16 input stream")
            }
            SampleFormat::F32 => {
                let buffer = Arc::clone(&buffer);
                let mut mono = Vec::new();
                let mut resampled = Vec::new();
                device
                    .build_input_stream(
                        &config,
                        move |data: &[f32], _: &cpal::InputCallbackInfo| {
                            mix_f32_to_mono(data, channels, &mut mono);
                            if device_sr != target_sr {
                                resample_into(&mono, resample_ratio, &mut resampled);
                                append_audio(&buffer, &resampled, max_samples);
                            } else {
                                append_audio(&buffer, &mono, max_samples);
                            }
                        },
                        |err| eprintln!("[typeoff] Audio error: {}", err),
                        None,
                    )
                    .expect("Failed to build f32 input stream")
            }
            other => panic!("Unsupported audio sample format: {:?}", other),
        };

        stream.play().expect("Failed to start recording");
        self.stream = Some(stream);
    }

    pub fn stop(&mut self) -> Vec<f32> {
        self.stream = None;
        let mut buffer = self.buffer.lock().unwrap();
        let audio = buffer.snapshot();
        buffer.clear();
        audio
    }

    pub fn len_samples(&self) -> usize {
        self.buffer.lock().unwrap().len()
    }

    pub fn with_audio<R>(&self, f: impl FnOnce(&[f32]) -> R) -> R {
        let buffer = self.buffer.lock().unwrap();
        f(buffer.as_slice())
    }

    pub fn snapshot(&self) -> Vec<f32> {
        self.buffer.lock().unwrap().snapshot()
    }

    pub fn snapshot_tail(&self, tail_samples: usize) -> Vec<f32> {
        self.buffer.lock().unwrap().snapshot_tail(tail_samples)
    }

    pub fn discard_front(&self, samples: usize) {
        self.buffer.lock().unwrap().discard_front(samples);
    }
}
