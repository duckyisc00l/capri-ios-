import Foundation
import AVFoundation
import Speech

/// Speech in (mic → text) and speech out (Capri's replies read aloud).
@MainActor
final class Voice: NSObject, ObservableObject {
    @Published var listening = false
    @Published var speaking = false
    @Published var partial = ""
    @Published var level: Float = 0

    private let synth = AVSpeechSynthesizer()
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var heardAnything = false
    private var finish: ((String?, String?) -> Void)?

    override init() {
        super.init()
        synth.delegate = self
    }

    // MARK: speech out

    func speak(_ text: String, locale: String) {
        let clean = Self.speakable(text)
        guard !clean.isEmpty else { return }
        stopSpeaking()
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? s.setActive(true)
        let u = AVSpeechUtterance(string: clean)
        let id = locale.replacingOccurrences(of: "_", with: "-")
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == id || $0.language.hasPrefix(String(id.prefix(2))) }
        u.voice = voices.first { $0.gender == .female && $0.quality != .default }
            ?? voices.first { $0.gender == .female }
            ?? voices.first
            ?? AVSpeechSynthesisVoice(language: id)
        u.pitchMultiplier = 1.15
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 1.02
        synth.speak(u)
    }

    func stopSpeaking() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        speaking = false
    }

    static func speakable(_ text: String) -> String {
        var t = text.replacingOccurrences(of: "```.*?(```|$)", with: " ", options: [.regularExpression])
        t = t.replacingOccurrences(of: "<think>.*?(</think>|$)", with: " ", options: [.regularExpression])
        t = t.replacingOccurrences(of: "[*_`#>|~]", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\[([^\\]]*)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: speech in

    /// Starts listening. `done` gets the text, or an error key ("voice_failed", "voice_empty", "mic_silent").
    func listen(locale: String, done: @escaping (String?, String?) -> Void) {
        stopSpeaking()
        finish = done
        partial = ""
        heardAnything = false
        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in
                guard status == .authorized else { self.end(nil, "voice_failed"); return }
                AVAudioSession.sharedInstance().requestRecordPermission { ok in
                    Task { @MainActor in
                        if ok { self.startEngine(locale) } else { self.end(nil, "voice_failed") }
                    }
                }
            }
        }
    }

    private func startEngine(_ locale: String) {
        guard let rec = SFSpeechRecognizer(locale: Locale(identifier: locale.replacingOccurrences(of: "_", with: "-"))),
              rec.isAvailable else { end(nil, "voice_failed"); return }
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
            try s.setActive(true, options: .notifyOthersOnDeactivation)
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            if rec.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = false }
            request = req
            let input = engine.inputNode
            let fmt = input.outputFormat(forBus: 0)
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
                req.append(buf)
                guard let ch = buf.floatChannelData?[0] else { return }
                var sum: Float = 0
                let n = Int(buf.frameLength)
                for i in 0..<n { sum += ch[i] * ch[i] }
                let rms = n > 0 ? sqrt(sum / Float(n)) : 0
                Task { @MainActor in
                    self?.level = rms
                    if rms > 0.003 { self?.heardAnything = true }
                }
            }
            engine.prepare()
            try engine.start()
            listening = true
            task = rec.recognitionTask(with: req) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let result {
                        self.partial = result.bestTranscription.formattedString
                        if result.isFinal { self.end(self.partial, nil) }
                    } else if error != nil, self.listening {
                        self.end(self.partial.isEmpty ? nil : self.partial, self.partial.isEmpty ? "voice_empty" : nil)
                    }
                }
            }
        } catch {
            end(nil, "voice_failed")
        }
    }

    /// Stops listening and sends what was heard.
    func stopListening() {
        guard listening else { return }
        request?.endAudio()
        let text = partial
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self, self.listening else { return }
            if text.isEmpty && self.partial.isEmpty {
                self.end(nil, self.heardAnything ? "voice_empty" : "mic_silent")
            } else {
                self.end(self.partial.isEmpty ? text : self.partial, nil)
            }
        }
    }

    private func end(_ text: String?, _ err: String?) {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        task?.cancel(); task = nil
        request = nil
        listening = false
        level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        let f = finish; finish = nil
        let t = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let t, !t.isEmpty { f?(t, nil) } else { f?(nil, err ?? "voice_empty") }
    }
}

extension Voice: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart u: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = true }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = false }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = false }
    }
}
