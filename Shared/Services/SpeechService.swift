import Foundation
@preconcurrency import Speech
@preconcurrency import AVFoundation
import Observation

/// The audio tap runs off the main actor. Swap recognition requests under a lock
/// so the microphone can stay open between short, independent utterances.
private final class SpeechAudioSink: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func set(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        self.request = request
        lock.unlock()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        request?.append(buffer)
        lock.unlock()
    }
}

@MainActor
@Observable final class SpeechService: NSObject, AVSpeechSynthesizerDelegate {
    var transcript = ""
    var isRecording = false
    var isStarting = false
    var level: Float = 0
    var error: String?
    var isSpeaking = false
    var onUtterance: ((String) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-AU"))
    private let engine = AVAudioEngine()
    private let sink = SpeechAudioSink()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var pauseTask: Task<Void, Never>?
    private var rolloverTask: Task<Void, Never>?
    private var hasTap = false
    private var generation = UUID()
    private let synthesizer = AVSpeechSynthesizer()
    private var chimePlayer: AVAudioPlayer?
    private var resumeTask: Task<Void, Never>?

    func start() async {
        guard !isRecording, !isStarting else { return }
        isStarting = true
        error = nil
        transcript = ""
        synthesizer.delegate = self
        let token = UUID()
        generation = token
        defer { isStarting = false }
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in
                continuation.resume(returning: status)
            }
        }
        #if os(iOS)
        let audio = await AVAudioApplication.requestRecordPermission()
        #else
        let audio = await AVCaptureDevice.requestAccess(for: .audio)
        #endif
        guard generation == token, !Task.isCancelled else { return }
        guard status == .authorized, audio else {
            error = "Allow microphone and speech access in Settings."
            return
        }
        guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            error = "On-device speech isn't available right now. Try typing instead."
            return
        }
        do {
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true)
            #endif
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                error = "No microphone is available."
                stop()
                return
            }
            let sink = self.sink
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable [weak self] buffer, _ in
                sink.append(buffer)
                var power: Float = 0
                if let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 {
                    for index in 0..<Int(buffer.frameLength) { power += samples[index] * samples[index] }
                    power = min(1, sqrt(power / Float(buffer.frameLength)) * 12)
                }
                let meter = power
                Task { @MainActor [weak self] in
                    guard let self, self.isRecording else { return }
                    self.level = meter
                }
            }
            hasTap = true
            isRecording = true
            beginUtterance()
            engine.prepare()
            try engine.start()
        } catch {
            self.error = "Couldn't start the microphone. Try again."
            stop()
        }
    }

    private func beginUtterance() {
        guard isRecording, !isSpeaking, let recognizer else { return }
        let token = UUID()
        generation = token
        transcript = ""
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        self.request = request
        sink.set(request)
        recognition = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor [weak self] in
                guard let self, self.isRecording, self.generation == token else { return }
                if let text, text != self.transcript {
                    self.transcript = text
                    self.pauseTask?.cancel()
                    self.pauseTask = Task { [weak self] in
                        try? await Task.sleep(for: .milliseconds(1500))
                        guard !Task.isCancelled, let self, self.generation == token else { return }
                        self.completeUtterance()
                    }
                }
                if final {
                    self.completeUtterance()
                } else if failed {
                    self.error = "Voice input stopped. Tap the microphone to try again."
                    self.stop()
                }
            }
        }
        // Apple's recognizer has a session limit. Renew it without switching off
        // voice mode, even when the user takes a long pause between items.
        rolloverTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(45))
            guard !Task.isCancelled, let self, self.generation == token else { return }
            self.completeUtterance()
        }
    }

    private func completeUtterance() {
        let phrase = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        cancelRecognition()
        // Restart immediately; item classification and saving happen separately.
        beginUtterance()
        if !phrase.isEmpty { onUtterance?(phrase) }
    }

    private func cancelRecognition() {
        generation = UUID() // Late partial/final callbacks belong to the old phrase.
        pauseTask?.cancel()
        rolloverTask?.cancel()
        pauseTask = nil
        rolloverTask = nil
        sink.set(nil)
        request?.endAudio()
        recognition?.cancel()
        recognition = nil
        request = nil
        transcript = ""
    }

    func stop(flush: Bool = false) {
        let finalPhrase = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        isRecording = false
        resumeTask?.cancel()
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        chimePlayer?.stop()
        cancelRecognition()
        engine.stop()
        if hasTap { engine.inputNode.removeTap(onBus: 0); hasTap = false }
        level = 0
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        if flush && !finalPhrase.isEmpty { onUtterance?(finalPhrase) }
    }

    /// Brief spoken replies suspend recognition so the app cannot add its own
    /// words. The microphone session resumes automatically after output drains.
    func say(_ message: String) {
        guard isRecording else { return }
        let pending = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        isSpeaking = true
        resumeTask?.cancel()
        cancelRecognition()
        if !pending.isEmpty { onUtterance?(pending) }
        let utterance = AVSpeechUtterance(string: message)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-AU")
        synthesizer.speak(utterance)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, !self.synthesizer.isSpeaking else { return }
            self.resumeTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, let self else { return }
                self.isSpeaking = false
                if self.isRecording { self.beginUtterance() }
            }
        }
    }

    /// A short, low-volume tone can play while recognition continues.
    func chime() {
        guard isRecording, !isSpeaking else { return }
        if chimePlayer == nil {
            let rate = 22_050
            let count = rate / 8
            var samples = Data()
            for index in 0..<count {
                let t = Double(index) / Double(rate)
                let envelope = min(1, Double(index) / 100) * exp(-t * 35)
                var sample = Int16(sin(t * 2 * .pi * 880) * envelope * 5_000).littleEndian
                withUnsafeBytes(of: &sample) { samples.append(contentsOf: $0) }
            }
            var wav = Data()
            func word(_ value: UInt32, bytes: Int = 4) {
                for offset in 0..<bytes { wav.append(UInt8(truncatingIfNeeded: value >> (offset * 8))) }
            }
            wav.append(contentsOf: "RIFF".utf8); word(UInt32(36 + samples.count))
            wav.append(contentsOf: "WAVEfmt ".utf8); word(16); word(1, bytes: 2); word(1, bytes: 2)
            word(UInt32(rate)); word(UInt32(rate * 2)); word(2, bytes: 2); word(16, bytes: 2)
            wav.append(contentsOf: "data".utf8); word(UInt32(samples.count)); wav.append(samples)
            chimePlayer = try? AVAudioPlayer(data: wav)
            chimePlayer?.prepareToPlay()
        }
        chimePlayer?.currentTime = 0
        chimePlayer?.play()
    }
}
