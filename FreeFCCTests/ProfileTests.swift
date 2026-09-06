import Foundation
import Testing
@testable import FreeFCC

/// Checks on the profiles as shipped in the app bundle. The timing ones are
/// the load-bearing ones: the burst only works if it fits inside the
/// service-mode window frame 1 opens and the last frame closes.
struct ProfileTests {

    private func loadFcc() throws -> Profile {
        try ProfileLoader.load(ProfileLoader.fccProfileName, bundle: .main)
    }

    @Test func hexParsingRoundTrips() throws {
        #expect(try ProfileLoader.hexToBytes("") == [])
        #expect(try ProfileLoader.hexToBytes("00ff10") == [0x00, 0xFF, 0x10])
        #expect(try ProfileLoader.hexToBytes("00 ff 10") == [0x00, 0xFF, 0x10])
        #expect(throws: ProfileError.self) { try ProfileLoader.hexToBytes("abc") }
        #expect(throws: ProfileError.self) { try ProfileLoader.hexToBytes("zz") }
    }

    @Test func fccProfileIsInTheBundle() throws {
        let profile = try loadFcc()
        #expect(profile.frames.count == 22)
        #expect(profile.sender == 0x82)
        #expect(profile.rounds == 2)

        // The profile sets the altitude ceiling to 500m by writing
        // g_config.flying_limit.max_height. The parameter is addressed by its
        // hash 0x0371238a, little-endian in the payload, followed by the value
        // 500 as a uint16 (0x01F4). This asserts that frame is present and
        // carries exactly 500, so a careless edit cannot silently change the
        // altitude the app claims to set.
        let maxHeightHashLE: [UInt8] = [0x8A, 0x23, 0x71, 0x03]
        let maxHeightFrame = profile.frames.first { $0.payload.starts(with: maxHeightHashLE) }
        let frame = try #require(maxHeightFrame, "max_height frame missing")
        let value = Int(frame.payload[4]) | (Int(frame.payload[5]) << 8)
        #expect(value == 500, "altitude ceiling should be 500m, got \(value)")
    }

    @Test func fccProfileKeepsTheBurstInsideTheServiceModeWindow() throws {
        let profile = try loadFcc()

        // A round is one pass through the sequence. Anything much over a second
        // and the radio stays on CE even though every write succeeded.
        let roundMs = profile.frames.count * profile.interFrameDelayMs
        #expect(roundMs < 1500, "round takes \(roundMs)ms, must stay under 1500ms")

        // An apply sweeps two sender bytes per framing, and the iOS build can
        // sweep two framings, so bound the worst case too.
        let sweepMs = 4 * profile.rounds * (roundMs + profile.interRoundDelayMs)
        #expect(sweepMs < 16000, "sweep takes \(sweepMs)ms, must stay under 16000ms")
    }

    @Test func fccProfileOpensAndClosesServiceMode() throws {
        let profile = try loadFcc()
        let first = try #require(profile.frames.first)
        let last = try #require(profile.frames.last)
        // AUTOTEST cmdSet 16 / cmdId 88 brackets the sequence.
        #expect(first.cmdSet == 16)
        #expect(first.cmdId == 88)
        #expect(last.cmdSet == 16)
        #expect(last.cmdId == 88)
    }

    @Test func everyFccFrameBuildsValidlyOnBothSenderBytes() throws {
        let profile = try loadFcc()
        for sender in [FccController.senderCapture, FccController.senderNet0] {
            var seq = 149
            for definition in profile.frames {
                let built = DumplBuilder.buildFrame(
                    DumplFrame(
                        sender: sender,
                        cmdType: profile.cmdType,
                        cmdSet: definition.cmdSet,
                        cmdId: definition.cmdId,
                        dst: definition.dst,
                        payload: definition.payload
                    ),
                    seq: seq
                )
                #expect(built.count <= DumplBuilder.maxFrameLength)
                #expect(built.count == definition.payload.count + 13)
                #expect(DumplBuilder.verifyCrc16(built))
                #expect(built[4] == UInt8(sender))
                seq = (seq + 1) & 0xFFFF
            }
        }
    }

    @Test func ceRestoreProfileIsASingleRadioFrame() throws {
        let profile = try ProfileLoader.load(ProfileLoader.ceRestoreProfileName, bundle: .main)
        #expect(profile.frames.count == 1)
        let frame = try #require(profile.frames.first)
        #expect(frame.cmdSet == 6)
        #expect(frame.cmdId == 114)
    }

    @Test func bootstrapAndKeepaliveFramesAreWellFormed() {
        for framing in Framing.allCases {
            for encoded in Bootstrap.frames(framing: framing) {
                let inner = framing == .rclink ? Array(encoded.dropFirst(RCLink.headerLength)) : encoded
                #expect(DumplBuilder.verifyCrc16(inner))
                #expect(inner[9] == 0x00, "bootstrap cmdSet")
            }
            for encoded in Keepalive.frames(framing: framing, route: RCLink.defaultRoute) {
                let inner = framing == .rclink ? Array(encoded.dropFirst(RCLink.headerLength)) : encoded
                #expect(DumplBuilder.verifyCrc16(inner))
                #expect(inner[9] == 0x06, "keepalive cmdSet")
                #expect(inner[10] == 0x77, "keepalive cmdId")
            }
        }
    }

    @Test func declaredProtocolsAreInTheInfoPlist() {
        let declared = ExternalAccessoryTransport.declaredProtocols
        #expect(!declared.isEmpty, "UISupportedExternalAccessoryProtocols is missing from Info.plist")
        #expect(declared.contains("com.dji.protocol"))
    }
}
