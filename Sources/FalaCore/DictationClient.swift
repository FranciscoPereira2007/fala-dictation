import Foundation
import Network

/// One authenticated request per TCP connection; no relay and no cleartext fallback.
enum DictationClient {
    static func send(_ body: Data, host: String, token: String, id: Data = LinkCrypto.newID(), port: UInt16 = DictationProtocol.port) async throws -> Data {
        guard !host.isEmpty, DictationProtocol.validToken(token), id.count == 16,
              body.count <= LinkCrypto.maxFrameSize - 52 else {
            throw ClientError.message("Check the Mac address and 26-character pairing code.")
        }
        let wire = LinkCrypto.seal(body, id: id, token: token)
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { throw ClientError.message("Invalid port.") }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
        return try await withCheckedThrowingContinuation { continuation in
            let exchange = Exchange(connection: connection, id: id, token: token, continuation: continuation)
            exchange.start(wire)
        }
    }

    enum ClientError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
    }

    private final class Exchange {
        let connection: NWConnection
        let id: Data
        let token: String
        let queue = DispatchQueue(label: "fala.dictation.exchange")
        var continuation: CheckedContinuation<Data, Error>?
        var timeout: DispatchWorkItem?
        var buffer = Data()
        init(connection: NWConnection, id: Data, token: String, continuation: CheckedContinuation<Data, Error>) {
            self.connection = connection; self.id = id; self.token = token; self.continuation = continuation
        }
        func finish(_ result: Result<Data, Error>) {
            guard let pending = continuation else { return }
            continuation = nil
            timeout?.cancel(); timeout = nil
            connection.stateUpdateHandler = nil
            connection.cancel()
            pending.resume(with: result)
        }
        func start(_ wire: Data) {
            let deadline = DispatchWorkItem { [self] in
                finish(.failure(ClientError.message("The Mac did not reply within 3 minutes. Check its model and network status.")))
            }
            timeout = deadline
            queue.asyncAfter(deadline: .now() + 180, execute: deadline)
            connection.stateUpdateHandler = { [self] state in
                if case .failed(let error) = state { finish(.failure(error)) }
                if case .ready = state {
                    connection.send(content: wire, completion: .contentProcessed { [self] error in
                        if let error { finish(.failure(error)) } else { receive() }
                    })
                }
            }
            connection.start(queue: queue)
        }
        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, complete, error in
                guard continuation != nil else { return }
                if let data { buffer.append(data) }
                if buffer.count > LinkCrypto.maxFrameSize + 6 { invalid(); return }
                if buffer.count >= 6 {
                    guard let length = LinkCrypto.frameLength(buffer), buffer.count <= length else { invalid(); return }
                    if buffer.count == length {
                        guard let body = LinkCrypto.openReply(buffer, id: id, token: token) else { invalid(); return }
                        finish(.success(body)); return
                    }
                }
                if let error { finish(.failure(error)) }
                else if complete { invalid() }
                else { receive() }
            }
        }
        func invalid() { finish(.failure(ClientError.message("Invalid or unauthenticated reply. Check the pairing code."))) }
    }
}
