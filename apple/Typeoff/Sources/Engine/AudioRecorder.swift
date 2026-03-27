import Foundation
import AVFoundation

/// Continuous audio recorder with rolling buffer access.
/// Feeds audio through bandpass filter + noise gate, then streams to mel processor.
final class AudioRecorder: ObservableObject {

    @MainActor @Published var isRecording = false
    @MainActor @Published var duration: TimeInterval = 0

    private let sampleRate: Double = 16000
    private var audioEngine: AVAudioEngine?
    private var buffer: [Float] = []
    private let bufferLock = NSLock()
    private var startTime: Date?
    private var durationTimer: Timer?

    private let preprocessor = AudioPreprocessor()

    /// Optional: stream audio to engine's mel processor for precomputation.
    var onAudioChunk: (([Float]) -> Void)?

    /// Called when recording is interrupted (phone call, Siri, etc.)
    var onInterruption: (() -> Void)?

    /// Called once after noise floor calibration (~0.5s) with the calibrated value.
    var onNoiseFloorCalibrated: ((Float) -> Void)?
    private var hasNotifiedCalibration = false

    // MARK: - Recording

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement)
        try session.setActive(true)

        // Handle interruptions (phone call, Siri, etc.)
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let info = notification.userInfo,
                  let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  typeValue == AVAudioSession.InterruptionType.began.rawValue else { return }
            print("[Typeoff] Audio interrupted — stopping recording")
            self?.onInterruption?()
        }

        preprocessor.reset()

        audioEngine = AVAudioEngine()
        guard let engine = audioEngine else { return }

        let inputNode = engine.inputNode
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: sampleRate,
                                   channels: 1,
                                   interleaved: false)!

        // Install tap — audio callback
        inputNode.installTap(onBus: 0, bufferSize: 4800, format: format) { [weak self] pcmBuffer, _ in
            guard let self = self,
                  let channelData = pcmBuffer.floatChannelData?[0] else { return }

            let frameCount = Int(pcmBuffer.frameLength)
            var samples = Array(UnsafeBufferPointer(start: channelData, count: frameCount))

            // Bandpass filter + noise gate
            self.preprocessor.process(&samples)

            self.bufferLock.lock()
            self.buffer.append(contentsOf: samples)
            self.bufferLock.unlock()

            // Notify when noise floor is calibrated (once)
            if !self.hasNotifiedCalibration && self.preprocessor.isCalibrated {
                self.hasNotifiedCalibration = true
                self.onNoiseFloorCalibrated?(self.preprocessor.noiseFloor)
            }

            // Stream to mel processor (precompute mel frames)
            self.onAudioChunk?(samples)
        }

        bufferLock.lock()
        buffer = []
        bufferLock.unlock()

        try engine.start()
        startTime = Date()
        Task { @MainActor in isRecording = true }

        // Update duration on main thread
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let start = self.startTime else { return }
            Task { @MainActor in self.duration = Date().timeIntervalSince(start) }
        }

        print("[Typeoff] Recording started (bandpass 80-8000 Hz + noise gate)")
    }

    func stop() -> [Float] {
        durationTimer?.invalidate()
        durationTimer = nil
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.interruptionNotification, object: nil)

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        Task { @MainActor in isRecording = false }

        bufferLock.lock()
        let audio = buffer
        buffer = []
        bufferLock.unlock()

        Task { @MainActor in
            duration = 0
        }
        startTime = nil

        print("[Typeoff] Recording stopped: \(String(format: "%.1f", Double(audio.count) / sampleRate))s")
        return audio
    }

    /// Get current audio buffer (non-destructive).
    func getAudio() -> [Float] {
        bufferLock.lock()
        let audio = buffer
        bufferLock.unlock()
        return audio
    }

    /// Get audio from a specific sample index onward (for sliding window).
    func getAudio(from sampleIndex: Int) -> [Float] {
        bufferLock.lock()
        let audio = sampleIndex < buffer.count ? Array(buffer[sampleIndex...]) : []
        bufferLock.unlock()
        return audio
    }

    /// Release audio samples before a given index (after window slide).
    /// Frees memory from already-flushed sentences.
    func trimAudio(before sampleIndex: Int) {
        bufferLock.lock()
        if sampleIndex > 0 && sampleIndex < buffer.count {
            buffer = Array(buffer[sampleIndex...])
        }
        bufferLock.unlock()
    }

    /// Current buffer length in seconds.
    var bufferDuration: TimeInterval {
        bufferLock.lock()
        let count = buffer.count
        bufferLock.unlock()
        return Double(count) / sampleRate
    }
}
