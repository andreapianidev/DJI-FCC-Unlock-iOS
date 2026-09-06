import Foundation
import Testing
@testable import FreeFCC

/// Wire-format tests for the DUML frame builder and the shipped profiles.
///
/// The production CRCs are table-driven. These recompute them bitwise straight
/// from the polynomials, so a corrupted or mistyped table entry shows up as a
/// mismatch rather than as frames the controller silently drops.
struct DumplBuilderTests {

    // MARK: Independent, from-spec CRC implementations

    /// CRC-8, polynomial 0x8C (reflected 0x31), init 0x77.
    private func crc8Bitwise(_ data: [UInt8], from: Int, to: Int) -> Int {
        var crc = 0x77
        for i in from..<to {
            crc ^= Int(data[i])
            for _ in 0..<8 {
                crc = (crc & 0x01) != 0 ? (crc >> 1) ^ 0x8C : crc >> 1
            }
        }
        return crc & 0xFF
    }

    /// CRC-16, polynomial 0x8408 (reflected 0x1021), init 0x3692.
    private func crc16Bitwise(_ data: [UInt8], from: Int, to: Int) -> Int {
        var crc = 0x3692
        for i in from..<to {
            crc ^= Int(data[i])
            for _ in 0..<8 {
                crc = (crc & 0x0001) != 0 ? (crc >> 1) ^ 0x8408 : crc >> 1
            }
        }
        return crc & 0xFFFF
    }

    // MARK: Frame structure

    @discardableResult
    private func buildAndCheck(
        sender: Int, cmdType: Int, cmdSet: Int, cmdId: Int, dst: Int,
        payload: [UInt8], seq: Int
    ) -> [UInt8] {
        let f = DumplBuilder.buildFrame(
            DumplFrame(sender: sender, cmdType: cmdType, cmdSet: cmdSet, cmdId: cmdId, dst: dst, payload: payload),
            seq: seq
        )

        let total = payload.count + 13
        #expect(f.count == total, "frame length")
        #expect(f[0] == 0x55, "magic")

        // Length in bits 0-9, version 1 in the high bits.
        let encodedLen = Int(f[1]) | (Int(f[2] & 0x03) << 8)
        #expect(encodedLen == total, "encoded length")
        #expect(f[2] & 0xFC == 0x04, "version bits")

        #expect(Int(f[3]) == crc8Bitwise(f, from: 0, to: 3), "crc8")

        #expect(Int(f[4]) == sender & 0xFF, "sender")
        #expect(Int(f[5]) == dst & 0xFF, "dst")
        #expect(Int(f[6]) == seq & 0xFF, "seq lo")
        #expect(Int(f[7]) == (seq >> 8) & 0xFF, "seq hi")
        #expect(Int(f[8]) == cmdType & 0xFF, "cmdType")
        #expect(Int(f[9]) == cmdSet & 0xFF, "cmdSet")
        #expect(Int(f[10]) == cmdId & 0xFF, "cmdId")

        #expect(Array(f[11..<(11 + payload.count)]) == payload, "payload")

        let expected = crc16Bitwise(f, from: 0, to: 11 + payload.count)
        let stored = Int(f[total - 2]) | (Int(f[total - 1]) << 8)
        #expect(stored == expected, "crc16")
        #expect(DumplBuilder.verifyCrc16(f), "verifyCrc16 agrees")

        return f
    }

    @Test func emptyPayloadFrameIsWellFormed() {
        buildAndCheck(sender: 0xA2, cmdType: 0x40, cmdSet: 0x51, cmdId: 0x04, dst: 0xEE, payload: [], seq: 149)
    }

    @Test func bootstrapFrameIsWellFormed() {
        buildAndCheck(sender: 0x02, cmdType: 0x40, cmdSet: 0x00, cmdId: 0x00, dst: 0x1F, payload: [0, 0, 1], seq: 4096)
    }

    @Test func crcTablesMatchThePolynomialsAcrossTheByteRange() {
        // Every payload length and byte value exercised through the real builder.
        for len in 0...64 {
            let payload = (0..<len).map { UInt8(($0 * 7 + len * 13) & 0xFF) }
            buildAndCheck(sender: 0x82, cmdType: 0x20, cmdSet: 0x03, cmdId: 0xF9, dst: 0x03,
                          payload: payload, seq: (len * 37) & 0xFFFF)
        }
    }

    @Test func sequenceNumberWrapsWithinTwoBytes() {
        buildAndCheck(sender: 0x02, cmdType: 0x40, cmdSet: 0x06, cmdId: 0x77, dst: 0x06,
                      payload: [0, 0, 0, 0], seq: 0xFFFF)
        buildAndCheck(sender: 0x02, cmdType: 0x40, cmdSet: 0x06, cmdId: 0x77, dst: 0x06,
                      payload: [0, 0, 0, 0], seq: 0)
    }

    @Test func globalSequenceCounterWrapsAndNeverRepeatsInAWindow() {
        let counter = SequenceCounter(start: 0xFFFE)
        #expect(counter.next() == 0xFFFE)
        #expect(counter.next() == 0xFFFF)
        #expect(counter.next() == 0x0000)
    }

    // MARK: RCLink envelope

    @Test func rclinkEnvelopeCarriesHeaderRouteAndLittleEndianLength() {
        let inner = DumplBuilder.buildFrame(
            DumplFrame(sender: 0x82, cmdType: 0x20, cmdSet: 0x06, cmdId: 0x72, dst: 0x06, payload: [UInt8](repeating: 0, count: 7)),
            seq: 200
        )
        let wrapped = RCLink.wrap(inner)

        #expect(wrapped.count == 8 + inner.count)
        #expect(wrapped[0] == 0x55)
        #expect(wrapped[1] == 0xCC)
        #expect(wrapped[2] == 0x49)
        #expect(wrapped[3] == 0x57)

        let len = Int(wrapped[4]) | (Int(wrapped[5]) << 8) | (Int(wrapped[6]) << 16) | (Int(wrapped[7]) << 24)
        #expect(len == inner.count)
        #expect(Array(wrapped[8...]) == inner)
    }

    @Test func rclinkEnvelopeHonoursARouteTheControllerChanged() {
        let inner = DumplBuilder.buildFrame(
            DumplFrame(sender: 0x02, cmdType: 0x40, cmdSet: 0, cmdId: 0, dst: 0x1F, payload: [0, 0, 0]),
            seq: 1
        )
        let wrapped = RCLink.wrap(inner, route: [0x11, 0x22])
        #expect(wrapped[2] == 0x11)
        #expect(wrapped[3] == 0x22)
    }

    @Test func rawFramingLeavesTheFrameAlone() {
        let inner = DumplBuilder.buildFrame(
            DumplFrame(sender: 0x82, cmdType: 0x20, cmdSet: 6, cmdId: 114, dst: 6, payload: [1, 2, 3]),
            seq: 7
        )
        #expect(RCLink.encode(inner, framing: .raw) == inner)
        #expect(RCLink.encode(inner, framing: .rclink) == RCLink.wrap(inner))
    }
}
