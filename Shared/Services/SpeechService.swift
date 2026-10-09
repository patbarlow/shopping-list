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
@Observable final class SpeechService {
    var transcript = ""
    var isRecording = false
    var isStarting = false
    var level: Float = 0
    var error: String?
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

    func start() async {
        guard !isRecording, !isStarting else { return }
        isStarting = true
        error = nil
        transcript = ""
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
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
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
        guard isRecording, let recognizer else { return }
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
        cancelRecognition()
        engine.stop()
        if hasTap { engine.inputNode.removeTap(onBus: 0); hasTap = false }
        level = 0
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        if flush && !finalPhrase.isEmpty { onUtterance?(finalPhrase) }
    }
}
