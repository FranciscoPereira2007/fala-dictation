import SwiftUI
import AVFoundation

@main struct FalaDictationPhone: App {
    @StateObject private var model = PhoneModel()
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                Form {
                    Section("Pair with your Mac") {
                        TextField("Mac IP address (e.g. 192.168.1.20)", text: $model.host)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        SecureField("26-character pairing code", text: $model.token)
                            .textInputAutocapitalization(.characters).autocorrectionDisabled()
                        Button("Test connection") { model.ping() }.disabled(model.busy || model.recording)
                        Text("Open Fala Dictation on your Mac. Use the address and code shown there. Both devices must be on the same network.")
                            .font(.caption)
                    }.disabled(model.recording)
                    Section("Dictate") {
                        Button(model.recording ? "Stop and send to Mac" : "Record") {
                            if model.recording { model.stop() } else { Task { await model.record() } }
                        }.disabled(model.busy)
                        if model.recording { Button("Cancel recording", role: .destructive) { model.cancel() } }
                        Text(model.status)
                        Text("Up to 2 minutes per recording. Keep this app open. Transcription runs on your Mac; pasting is controlled in the Mac window.")
                            .font(.caption)
                    }
                    Section("Transcript") {
                        Text(model.text.isEmpty ? "Your transcript will appear here." : model.text).textSelection(.enabled)
                        if !model.text.isEmpty {
                            ShareLink("Share transcript", item: model.text)
                            Button("Clear transcript") { model.text = "" }
                        }
                    }
                }.navigationTitle("Fala Dictation")
            }.onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                if model.recording { model.cancel(); model.status = "Recording cancelled when the app entered the background." }
            }
        }
    }
}

@MainActor final class PhoneModel: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published var host = ""
    @Published var token = ""
    @Published var recording = false
    @Published var busy = false
    @Published var status = "Pair your Mac to begin."
    @Published var text = ""
    private var recorder: AVAudioRecorder?
    private var audioURL: URL?

    func ping() {
        guard validate() else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let response = try await DictationClient.send(Data("P".utf8), host: host, token: token)
                status = response.first == 0x50 ? "Connected: " + String(decoding: response.dropFirst(), as: UTF8.self) : "Unexpected reply."
            } catch { status = error.localizedDescription }
        }
    }
    private func validate() -> Bool {
        host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        token = token.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !host.isEmpty, DictationProtocol.validToken(token) else {
            status = "Enter the Mac address and its 26-character pairing code."; return false
        }
        return true
    }
    func record() async {
        guard !busy, !recording, validate() else { return }
        busy = true
        defer { busy = false }
        guard await AVAudioApplication.requestRecordPermission() else { status = "Allow microphone access in Settings."; return }
        guard UIApplication.shared.applicationState == .active else { status = "Return to the app to record."; return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement)
            try session.setActive(true)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
            audioURL = url
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false]
            let value = try AVAudioRecorder(url: url, settings: settings)
            value.delegate = self
            guard value.record(forDuration: 120) else { cancel(); status = "Could not start microphone."; return }
            recorder = value; recording = true; status = "Recording…"
        } catch { cancel(); status = error.localizedDescription }
    }
    func cancel() {
        recorder?.delegate = nil; recorder?.stop(); recorder = nil; recording = false
        if let audioURL { try? FileManager.default.removeItem(at: audioURL) }
        audioURL = nil
        try? AVAudioSession.sharedInstance().setActive(false)
        status = "Recording cancelled."
    }
    func stop() {
        guard recording, let url = audioURL else { return }
        recorder?.delegate = nil; recorder?.stop(); recorder = nil; recording = false; audioURL = nil
        try? AVAudioSession.sharedInstance().setActive(false)
        busy = true; status = "Transcribing on your Mac…"
        let host = host, token = token
        Task {
            defer { busy = false }
            let body = await Task.detached { () -> Data? in
                defer { try? FileManager.default.removeItem(at: url) }
                guard let data = try? Data(contentsOf: url), let samples = AudioCodec.decode(data) else { return nil }
                return DictationProtocol.audio(samples)
            }.value
            guard let body else { status = "Could not read recording."; return }
            do {
                let response = try await DictationClient.send(body, host: host, token: token)
                let message = String(decoding: response.dropFirst(), as: UTF8.self)
                if response.first == 0x54 { text = message; status = message.isEmpty ? "No speech detected." : "Transcript received." }
                else { status = response.first == 0x45 ? message : "Mac is busy. Please try again." }
            } catch { status = error.localizedDescription }
        }
    }
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            guard recorder === self.recorder else { return }
            if flag { stop() } else { cancel(); status = "Recording failed." }
        }
    }
}
