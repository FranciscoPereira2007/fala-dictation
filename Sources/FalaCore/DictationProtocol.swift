import Foundation

enum DictationProtocol {
    static let port: UInt16 = 47831
    static let service = "_falacore._tcp"
    static let maxSamples = 120 * 16000

    static func newToken() -> String {
        let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
        var rng = SystemRandomNumberGenerator()
        return String((0..<26).map { _ in alphabet.randomElement(using: &rng)! })
    }

    static func validToken(_ value: String) -> Bool {
        value.count == 26 && value.allSatisfy { "ABCDEFGHJKMNPQRSTUVWXYZ23456789".contains($0) }
    }

    // Narrow Fala v2 subset: ping P; audio a0R + Int16 LE mono, 16 kHz.
    // The open core never accepts arbitrary text, remote commands or automatic Enter.
    static func audio(_ samples: [Float]) -> Data? {
        guard !samples.isEmpty, samples.count <= maxSamples,
              samples.allSatisfy({ $0.isFinite }) else { return nil }
        var data = Data("a0R".utf8)
        for sample in samples {
            var value = Int16(max(-1, min(1, sample)) * 32767).littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func samples(_ body: Data) -> [Float]? {
        guard body.prefix(3) == Data("a0R".utf8), body.count > 3,
              (body.count - 3) % 2 == 0,
              (body.count - 3) / 2 <= maxSamples else { return nil }
        return Data(body.dropFirst(3)).withUnsafeBytes { raw in
            (0..<(raw.count / 2)).map {
                Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))) / 32767
            }
        }
    }
}
