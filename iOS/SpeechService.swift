import Foundation
import Speech
import AVFoundation
import Observation

@MainActor
@Observable final class SpeechService {
    var transcript  = ""
    var isRecording = false
    var isAvailable = false

    /// Called with the final (committed) transcript when speech ends naturally.
    var onFinalResult: ((String) -> Void)?

    private var recognizer     = SFSpeechRecognizer(locale: Locale(identifier: "en-AU"))
    private var audioEngine    = AVAudioEngine()
    private var recognitionReq: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    func requestPermission() async {
        let speechStatus = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        let audioGranted = await AVAudioApplication.requestRecordPermission()
        isAvailable = speechStatus == .authorized && audioGranted
    }

    func start() {
        guard isAvailable, let recognizer, recognizer.isAvailable, !isRecording else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            recognitionReq = SFSpeechAudioBufferRecognitionRequest()
            recognitionReq?.requiresOnDeviceRecognition = true
            recognitionReq?.shouldReportPartialResults   = true

            recognitionTask = recognizer.recognitionTask(with: recognitionReq!) { [weak self] result, error in
                DispatchQueue.main.async {
                    if let result {
                        self?.transcript = result.bestTranscription.formattedString
                        if result.isFinal {
                            let final = result.bestTranscription.formattedString
                            self?.stop()
                            if !final.isEmpty { self?.onFinalResult?(final) }
                        }
                    }
                    if error != nil { self?.stop() }
                }
            }

            let node   = audioEngine.inputNode
            let format = node.outputFormat(forBus: 0)
            node.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
                self?.recognitionReq?.append(buf)
            }
            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true
        } catch {
            stop()
        }
    }

    func stop() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionReq?.endAudio()
        recognitionReq  = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        try? AVAudioSession.sharedInstance().setActive(false)
        isRecording = false
    }
}
