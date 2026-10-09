import Foundation
@preconcurrency import Speech
@preconcurrency import AVFoundation
import Observation

@MainActor
@Observable final class SpeechService {
    var transcript = ""
    var isRecording = false
    var isStarting = false
    var level: Float = 0
    var error: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-AU"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var timeout: Task<Void, Never>?
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
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        #if os(iOS)
        let audio = await AVAudioApplication.requestRecordPermission()
        #else
        let audio = await AVCaptureDevice.requestAccess(for: .audio)
        #endif
        guard generation == token, !Task.isCancelled else { return }
        guard status == .authorized, audio else {
            error = "Allow microphone and speech recognition access in Settings to use voice entry."
            return
        }
        guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            error = "On-device English speech recognition isn't available on this device right now. You can still type your items."
            return
        }
        do {
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true)
            #endif
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = true
            request.taskHint = .dictation
            self.request = request
            recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let final = result?.isFinal ?? false
                let failed = error != nil
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token else { return }
                    if let text { self.transcript = text }
                    if final || failed {
                        if failed && self.transcript.isEmpty { self.error = "Couldn't hear any speech. Try again or type your items." }
                        self.stop()
                    }
                }
            }
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                error = "No microphone is available."
                stop()
                return
            }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                request.append(buffer)
                var power: Float = 0
                if let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 {
                    for index in 0..<Int(buffer.frameLength) { power += samples[index] * samples[index] }
                    power = min(1, sqrt(power / Float(buffer.frameLength)) * 12)
                }
                let meter = power
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token else { return }
                    self.level = meter
                }
            }
            hasTap = true
            engine.prepare()
            try engine.start()
            isRecording = true
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(45))
                guard !Task.isCancelled else { return }
                await self?.finish()
            }
        } catch {
            self.error = "Couldn't start the microphone: \(error.localizedDescription)"
            stop()
        }
    }

    /// Allow the recognizer to deliver the last words before cancelling its task.
    func finish() async {
        let token = generation
        engine.stop()
        if hasTap { engine.inputNode.removeTap(onBus: 0); hasTap = false }
        request?.endAudio()
        try? await Task.sleep(for: .milliseconds(600))
        guard generation == token else { return }
        stop()
    }

    func stop() {
        generation = UUID()
        timeout?.cancel()
        timeout = nil
        engine.stop()
        if hasTap { engine.inputNode.removeTap(onBus: 0); hasTap = false }
        request?.endAudio()
        recognition?.cancel()
        recognition = nil
        request = nil
        isRecording = false
        level = 0
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}
