import Foundation
import Network

/// All connection state is confined to the main actor. Model work runs in WhisperKit's async engine.
@MainActor final class DictationServer {
    let token: String
    var onAudio: (([Float], @escaping () -> Bool) async -> String?)?
    var onStatus: ((String) -> Void)?
    private let replay = ReplayGuard()
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var transcribing = false
    private var stopped = false
    private let requestedPort: UInt16
    private(set) var boundPort: UInt16 = 0

    init(token: String, port: UInt16 = DictationProtocol.port) { self.token = token; self.requestedPort = port }
    func start() {
        do {
            let value = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: requestedPort)!)
            value.service = NWListener.Service(name: "Fala Dictation", type: DictationProtocol.service)
            value.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    if case .ready = state { self?.boundPort = self?.listener?.port?.rawValue ?? 0; self?.onStatus?("Listening. Model downloads on first use; keep the Mac awake.") }
                    if case .failed(let error) = state { self?.onStatus?("Network error: \(error)") }
                }
            }
            value.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener = value
            value.start(queue: .main)
        } catch { onStatus?("Cannot listen: \(error)") }
    }
    func stop() {
        stopped = true
        listener?.cancel()
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
    }
    private func accept(_ connection: NWConnection) {
        guard !stopped, connections.count < 4 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: .main)
        // Includes model time. Resource count stays occupied until the reply/timeout.
        DispatchQueue.main.asyncAfter(deadline: .now() + 180) { [weak self] in self?.close(id) }
        receive(connection, id: id, buffer: Data())
    }
    private func close(_ id: UUID) { connections.removeValue(forKey: id)?.cancel() }
    private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] bytes, _, complete, error in
            Task { @MainActor in
                guard let self, self.connections[id] != nil else { return }
                var data = buffer
                if let bytes { data.append(bytes) }
                guard data.count <= LinkCrypto.maxFrameSize + 6 else { self.close(id); return }
                if data.count >= 6 {
                    guard let length = LinkCrypto.frameLength(data), data.count <= length else { self.close(id); return }
                    if data.count == length { await self.handle(data, connection: connection, id: id); return }
                }
                if complete || error != nil { self.close(id) }
                else { self.receive(connection, id: id, buffer: data) }
            }
        }
    }
    private func handle(_ data: Data, connection: NWConnection, id: UUID) async {
        let token = token
        guard let request = await Task.detached(operation: { LinkCrypto.open(data, token: token) }).value,
              !stopped, connections[id] != nil else { close(id); return }
        func send(_ body: Data) {
            guard !stopped, connections[id] != nil else { return }
            connection.send(content: LinkCrypto.sealReply(body, id: request.id, token: token),
                            completion: .contentProcessed { [weak self] _ in
                Task { @MainActor in self?.close(id) }
            })
        }
        switch replay.check(request) {
        case .stale: send(Data("EExpired request".utf8)); return
        case .duplicate(let cached): send(cached ?? Data("B".utf8)); return
        case .fresh: break
        }
        func finish(_ body: Data) { replay.store(request.id, reply: body); send(body) }
        if request.body == Data("P".utf8) { finish(Data("PFala Dictation".utf8)); return }
        guard !transcribing else { finish(Data("EBusy; try again after the current dictation".utf8)); return }
        transcribing = true
        defer { transcribing = false }
        guard let samples = await Task.detached(operation: { DictationProtocol.samples(request.body) }).value else {
            finish(Data("EUnsupported audio request".utf8)); return
        }
        let text = await onAudio?(samples, { [weak self] in self?.connections[id] != nil && self?.stopped == false })
        finish(Data((text.map { "T" + $0 } ?? "ETranscription failed; see the Mac window").utf8))
    }
}
