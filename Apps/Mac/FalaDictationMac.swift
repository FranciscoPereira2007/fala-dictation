import SwiftUI
import AppKit
import Network

@main struct FalaDictationMac: App {
    @StateObject private var model = DesktopModel()
    var body: some Scene {
        WindowGroup("Fala Dictation") {
            VStack(alignment: .leading, spacing: 16) {
                Text("Fala Dictation").font(.largeTitle.bold())
                Text("Your phone records. Your Mac transcribes.")
                Text(model.status).foregroundStyle(.secondary)
                Text("Mac address: \(model.addresses)").textSelection(.enabled)
                Text("Port: \(DictationProtocol.port)")
                Text("Pairing code — keep private").font(.headline)
                Text(model.token).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                Button("New pairing code") { model.rotateToken() }
                HStack {
                    Text("Transcription language")
                    Picker("Language", selection: $model.language) {
                        Text("Português").tag("pt")
                        Text("English").tag("en")
                    }.labelsHidden().frame(width: 160)
                }
                Toggle("Paste incoming dictation into the active app", isOn: $model.paste)
                Text("Off by default. Enable only when ready to dictate. Accessibility permission is required to paste.")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: .constant(model.text)).frame(minHeight: 100)
                HStack {
                    Button("Copy transcript") { model.copy() }.disabled(model.text.isEmpty)
                    Button("Clear transcript") { model.text = "" }
                    Button("Accessibility settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                }
            }.padding(24).frame(minWidth: 620, minHeight: 480)
                .task { model.start() }
        }
    }
}

@MainActor final class DesktopModel: ObservableObject {
    @Published var status = "Starting…"
    @Published var text = ""
    @Published var paste = false
    @Published var language = "pt" {
        didSet { UserDefaults.standard.set(language, forKey: "falaDictation.language") }
    }
    @Published private(set) var token: String
    var addresses: String {
        // Local interfaces only; no external IP lookup.
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0 else { return "Use Network settings → Wi-Fi → Details" }
        defer { freeifaddrs(pointer) }
        var list: [String] = []
        var item = pointer
        while let current = item {
            let value = current.pointee
            if let addr = value.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
               value.ifa_flags & UInt32(IFF_LOOPBACK) == 0 {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    list.append(String(cString: host))
                }
            }
            item = value.ifa_next
        }
        return list.joined(separator: " / ")
    }
    private var server: DictationServer?
    private var inferenceBusy = false
    init() {
        let saved = UserDefaults.standard.string(forKey: "falaDictation.token") ?? ""
        token = DictationProtocol.validToken(saved) ? saved : DictationProtocol.newToken()
        UserDefaults.standard.set(token, forKey: "falaDictation.token")
        language = UserDefaults.standard.string(forKey: "falaDictation.language") ?? "pt"
    }
    func rotateToken() {
        server?.stop(); server = nil
        token = DictationProtocol.newToken()
        UserDefaults.standard.set(token, forKey: "falaDictation.token")
        paste = false
        start()
    }
    func start() {
        guard server == nil else { return }
        let engine = WhisperEngine.shared
        status = "Preparing local model (first launch downloads the model)…"
        engine.warmUp()
        let value = DictationServer(token: token)
        value.readiness = { engine.isReady ? "Model ready" : (engine.lastError.map { "Model error: " + $0 } ?? "Model preparing; wait before sending audio") }
        let pairedToken = token
        Task {
            let ready = await Task.detached { await engine.prepare() }.value
            guard self.token == pairedToken else { return }
            self.status = ready ? "Model ready. Listening for your phone." : "Model preparation failed: \(engine.lastError ?? "try restarting the app")"
        }
        value.onAudio = { [weak self] samples, isActive in
            guard let self, isActive(), !self.inferenceBusy else { return nil }
            guard engine.isReady else {
                self.status = "Model is still preparing. Wait for ‘Model ready’ before sending audio."
                return nil
            }
            self.inferenceBusy = true
            defer { self.inferenceBusy = false }
            self.status = "Transcribing locally…"
            guard let result = await Task.detached { await engine.transcribe(samples, waitForModel: true) }.value else {
                if isActive() && self.token == pairedToken { self.status = "Model error: \(engine.lastError ?? "transcription failed")" }
                return nil
            }
            guard isActive(), self.token == pairedToken else { return nil }
            self.text = result
            if self.paste && !result.isEmpty {
                self.copy()
                if AXIsProcessTrusted() {
                    let source = CGEventSource(stateID: .combinedSessionState)
                    let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
                    let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
                    down?.flags = .maskCommand; up?.flags = .maskCommand
                    down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)
                    self.status = "Transcript received; paste requested."
                } else { self.status = "Transcript copied. Grant Accessibility permission to paste." }
            } else { self.status = result.isEmpty ? "No speech detected." : "Transcript received." }
            return result
        }
        value.onStatus = { [weak self] status in self?.status = engine.isReady ? "Model ready. " + status : status }
        server = value
        value.start()
    }
    func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
