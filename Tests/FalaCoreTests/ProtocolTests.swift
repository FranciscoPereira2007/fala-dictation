import XCTest
@testable import FalaCore

final class ProtocolTests: XCTestCase {
    let token = String(repeating: "A", count: 26) // deterministic test fixture only

    func testPairingCodesHaveFullEntropyAlphabet() {
        let values = (0..<100).map { _ in DictationProtocol.newToken() }
        XCTAssertTrue(values.allSatisfy(DictationProtocol.validToken))
        XCTAssertEqual(Set(values).count, 100)
        XCTAssertFalse(DictationProtocol.validToken("short"))
        XCTAssertFalse(DictationProtocol.validToken(String(repeating: "0", count: 26)))
    }
    func testEncryptedRoundTripAndRequestBoundReply() throws {
        let id = LinkCrypto.newID(), body = Data("private dictation".utf8)
        let frame = LinkCrypto.seal(body, id: id, token: token)
        let request = try XCTUnwrap(LinkCrypto.open(frame, token: token))
        XCTAssertEqual(request.body, body)
        XCTAssertEqual(request.id, id)
        XCTAssertEqual(LinkCrypto.frameLength(frame), frame.count)
        let reply = LinkCrypto.sealReply(Data("Ttranscript".utf8), id: id, token: token)
        XCTAssertEqual(LinkCrypto.openReply(reply, id: id, token: token), Data("Ttranscript".utf8))
        XCTAssertNil(LinkCrypto.openReply(reply, id: LinkCrypto.newID(), token: token))
        XCTAssertNil(LinkCrypto.open(frame, token: "different pairing code"))
        XCTAssertNil(frame.range(of: body))
    }
    func testTamperingAndTruncationAreRejected() {
        let frame = LinkCrypto.seal(Data("a0Rtest".utf8), id: LinkCrypto.newID(), token: token)
        for index in 6..<frame.count {
            var changed = frame; changed[index] ^= 1
            XCTAssertNil(LinkCrypto.open(changed, token: token))
        }
        for length in 0..<frame.count {
            XCTAssertNil(LinkCrypto.open(Data(frame.prefix(length)), token: token))
        }
        XCTAssertNil(LinkCrypto.open(frame + Data([0]), token: token))
        XCTAssertNil(LinkCrypto.frameLength(Data([0x46, 0x32, 0xff, 0xff, 0xff, 0xff])))
        XCTAssertNil(LinkCrypto.frameLength(Data([0x46, 0x32, 0, 0, 0, 0])))
    }
    func testReplayCacheDoesNotProcessSameRequestTwice() throws {
        let guardrail = ReplayGuard(), now = Date()
        let request = try XCTUnwrap(LinkCrypto.open(LinkCrypto.seal(Data("P".utf8), id: LinkCrypto.newID(), token: token, now: now), token: token))
        guard case .fresh = guardrail.check(request, now: now) else { return XCTFail("Fresh request rejected") }
        guard case .duplicate(nil) = guardrail.check(request, now: now) else { return XCTFail("Pending replay accepted") }
        let reply = Data("Tdone".utf8)
        guardrail.store(request.id, reply: reply)
        guard case .duplicate(let cached) = guardrail.check(request, now: now) else { return XCTFail("Replay accepted") }
        XCTAssertEqual(cached, reply)
        guard case .stale = guardrail.check(request, now: now.addingTimeInterval(121)) else { return XCTFail("Old request accepted") }
        guard case .stale = guardrail.check(request, now: now.addingTimeInterval(-121)) else { return XCTFail("Future request accepted") }
    }
    func testReplayCacheIsBounded() {
        let guardrail = ReplayGuard(), now = Date()
        for _ in 0..<256 {
            let request = LinkCrypto.Request(id: LinkCrypto.newID(), sent: now, body: Data())
            guard case .fresh = guardrail.check(request, now: now) else { return XCTFail("Unexpected rejection") }
        }
        guard case .stale = guardrail.check(.init(id: LinkCrypto.newID(), sent: now, body: Data()), now: now) else {
            return XCTFail("Unbounded cache")
        }
    }
    func testAudioRoundTripAndLimits() throws {
        let input: [Float] = [-1, -0.5, 0, 0.5, 1]
        let data = try XCTUnwrap(DictationProtocol.audio(input))
        let result = try XCTUnwrap(DictationProtocol.samples(data))
        XCTAssertEqual(result.count, input.count)
        for (left, right) in zip(input, result) { XCTAssertEqual(left, right, accuracy: 0.00004) }
        XCTAssertNil(DictationProtocol.audio([]))
        XCTAssertNil(DictationProtocol.audio([.nan]))
        XCTAssertNil(DictationProtocol.audio([.infinity]))
        XCTAssertNil(DictationProtocol.audio(Array(repeating: 0, count: DictationProtocol.maxSamples + 1)))
        XCTAssertNil(DictationProtocol.samples(Data("A0Rxx".utf8))) // no remote paste command
        XCTAssertNil(DictationProtocol.samples(Data("a1Rxx".utf8))) // no automatic Enter
        XCTAssertNil(DictationProtocol.samples(Data("a0Rx".utf8))) // partial sample
    }
    func testNetworkClientAuthenticatesReplies() async throws {
        // An actual loopback listener exercises framing, network lifetime and request IDs.
        let listener = try NWListener(using: .tcp, on: .any)
        let ready = expectation(description: "listener ready")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            func read(_ accumulated: Data) {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { bytes, _, _, _ in
                    let data = accumulated + (bytes ?? Data())
                    guard let length = LinkCrypto.frameLength(data), data.count >= length else { read(data); return }
                    guard let request = LinkCrypto.open(data, token: self.token) else { connection.cancel(); return }
                    let reply = LinkCrypto.sealReply(Data("PFake Mac".utf8), id: request.id, token: self.token)
                    connection.send(content: reply, completion: .contentProcessed { _ in connection.cancel() })
                }
            }
            read(Data())
        }
        listener.start(queue: .global())
        defer { listener.cancel() }
        await fulfillment(of: [ready], timeout: 3)
        let port = try XCTUnwrap(listener.port).rawValue
        let reply = try await DictationClient.send(Data("P".utf8), host: "127.0.0.1", token: token, port: port)
        XCTAssertEqual(reply, Data("PFake Mac".utf8))
    }
}

import Network
