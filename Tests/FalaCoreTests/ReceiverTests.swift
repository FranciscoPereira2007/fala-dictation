import XCTest
@testable import FalaCore

final class ReceiverTests: XCTestCase {
    @MainActor func testRealReceiverReturnsCachedTranscriptWithoutRepeatingDelivery() async throws {
        let token = DictationProtocol.newToken()
        let server = DictationServer(token: token, port: 0)
        let ready = expectation(description: "receiver ready")
        server.onStatus = { _ in if server.boundPort != 0 { ready.fulfill() } }
        var deliveries = 0
        server.onAudio = { samples, isActive in
            XCTAssertTrue(isActive()); XCTAssertEqual(samples.count, 16000)
            deliveries += 1
            return "Synthetic test transcript"
        }
        server.start()
        defer { server.stop() }
        await fulfillment(of: [ready], timeout: 3)
        let audio = try XCTUnwrap(DictationProtocol.audio(Array(repeating: 0.1, count: 16000)))
        let id = LinkCrypto.newID()
        let first = try await DictationClient.send(audio, host: "127.0.0.1", token: token, id: id, port: server.boundPort)
        let retry = try await DictationClient.send(audio, host: "127.0.0.1", token: token, id: id, port: server.boundPort)
        XCTAssertEqual(first, Data("TSynthetic test transcript".utf8))
        XCTAssertEqual(first, retry)
        XCTAssertEqual(deliveries, 1)
    }

    @MainActor func testStopRevokesInFlightRequestBeforeDelivery() async throws {
        let token = DictationProtocol.newToken()
        let server = DictationServer(token: token, port: 0)
        let ready = expectation(description: "ready"), began = expectation(description: "inference began")
        let finished = expectation(description: "inference finished")
        server.onStatus = { _ in if server.boundPort != 0 { ready.fulfill() } }
        var delivered = false
        server.onAudio = { _, isActive in
            began.fulfill()
            try? await Task.sleep(for: .milliseconds(100))
            delivered = isActive()
            finished.fulfill()
            return "must not be delivered"
        }
        server.start()
        await fulfillment(of: [ready], timeout: 3)
        let port = server.boundPort
        let pending = Task {
            try? await DictationClient.send(DictationProtocol.audio([0.1])!, host: "127.0.0.1", token: token, port: port)
        }
        await fulfillment(of: [began], timeout: 3)
        server.stop()
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertFalse(delivered)
        let response = await pending.value
        XCTAssertNil(response)
    }

    @MainActor func testReceiverRejectsRemotePasteAndEnterCommands() async throws {
        let token = DictationProtocol.newToken(), ready = expectation(description: "ready")
        let server = DictationServer(token: token, port: 0)
        server.onStatus = { _ in if server.boundPort != 0 { ready.fulfill() } }
        server.onAudio = { _, _ in XCTFail("Unsupported command reached inference"); return "" }
        server.start()
        defer { server.stop() }
        await fulfillment(of: [ready], timeout: 3)
        for command in ["0arbitrary text", "A0Rxx", "a1Rxx", "J{}"] {
            let reply = try await DictationClient.send(Data(command.utf8), host: "127.0.0.1", token: token, port: server.boundPort)
            XCTAssertEqual(reply.first, 0x45)
        }
    }
}
