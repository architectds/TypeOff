import Foundation
import AVFoundation

/// Continuous audio recorder with rolling buffer access.
final class AudioRecorder: ObservableObject {

    @MainActor @Published var isRecording = false
    @MainActor @Published var duration: TimeInterval = 0

    private let sampleRate: Double = 16000
    private var audioEngine: AVAudioEngine?
    private var buffer: [Float] = []
    private let bufferLock = NSLock()
    private var startTime: Date?
    private var durationTimer: Timer?

    // MARK: - Recording

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement)
        try session.setActive(true)

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
            let samples = Array(UnsafeBufferPointer(start: channelData, count: frameCount))

            self.bufferLock.lock()
            self.buffer.append(contentsOf: samples)
            self.bufferLock.unlock()
        }

        bufferLock.lock()
        buffer = []
        bufferLock.unlock()

        try engine.start()
        startTime = Date()
        isRecording = true

        // Update duration on main thread
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let start = self.startTime else { return }
            self.duration = Date().timeIntervalSince(start)
        }

        print("[Typeoff] Recording started")
    }

    func stop() -> [Float] {
        durationTimer?.invalidate()
        durationTimer = nil

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        isRecording = false

        bufferLock.lock()
        let audio = buffer
        buffer = []
        bufferLock.unlock()

        duration = 0
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

    /// Current buffer length in seconds.
    var bufferDuration: TimeInterval {
        bufferLock.lock()
        let count = buffer.count
        bufferLock.unlock()
        return Double(count) / sampleRate
    }
}
