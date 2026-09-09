// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Andrea Piani. https://www.andreapiani.com
// FreeFCC for iOS. Free for noncommercial use only. See LICENSE and NOTICE.md.
// Attribution required; do not present this work as your own.
//

import Foundation
import Testing
@testable import FreeFCC

/// The MFi stream gives no frame boundaries, so the parser has to resynchronise
/// on its own. These feed it the awkward shapes a real stream produces.
struct DumplStreamParserTests {

    private func frame(cmdSet: Int, cmdId: Int, seq: Int, payload: [UInt8] = []) -> [UInt8] {
        DumplBuilder.buildFrame(
            DumplFrame(sender: 0x06, cmdType: 0x80, cmdSet: cmdSet, cmdId: cmdId, dst: 0x82, payload: payload),
            seq: seq
        )
    }

    @Test func parsesABareFrame() {
        var parser = DumplStreamParser()
        let out = parser.feed(frame(cmdSet: 6, cmdId: 114, seq: 3, payload: [1, 2, 3]))
        #expect(out.count == 1)
        let response = DumplResponse(frame: out[0])
        #expect(response?.cmdSet == 6)
        #expect(response?.cmdId == 114)
        #expect(response?.seq == 3)
        #expect(response?.isResponse == true)
        #expect(response?.payload == [1, 2, 3])
    }

    @Test func parsesAFrameSplitAcrossReads() {
        var parser = DumplStreamParser()
        let bytes = frame(cmdSet: 3, cmdId: 249, seq: 40, payload: [0xAA, 0xBB])
        let firstHalf = Array(bytes.prefix(5))
        let secondHalf = Array(bytes.dropFirst(5))
        #expect(parser.feed(firstHalf).isEmpty)
        let out = parser.feed(secondHalf)
        #expect(out.count == 1)
        #expect(out[0] == bytes)
    }

    @Test func parsesBackToBackFramesInOneRead() {
        var parser = DumplStreamParser()
        let a = frame(cmdSet: 6, cmdId: 0x77, seq: 1)
        let b = frame(cmdSet: 9, cmdId: 39, seq: 2, payload: [9, 9])
        let out = parser.feed(a + b)
        #expect(out.count == 2)
        #expect(out[0] == a)
        #expect(out[1] == b)
    }

    @Test func skipsLeadingGarbageAndStillFindsTheFrame() {
        var parser = DumplStreamParser()
        let good = frame(cmdSet: 6, cmdId: 114, seq: 9)
        let out = parser.feed([0x55, 0x01, 0x02, 0x03, 0xFF, 0x00] + good)
        #expect(out.count == 1)
        #expect(out[0] == good)
    }

    @Test func unwrapsAnRclinkEnvelopeAndRemembersTheRoute() {
        var parser = DumplStreamParser()
        let inner = frame(cmdSet: 16, cmdId: 88, seq: 12, payload: [3, 1, 0])
        let out = parser.feed(RCLink.wrap(inner, route: [0x41, 0x42]))
        #expect(out.count == 1)
        #expect(out[0] == inner)
        #expect(parser.lastRoute == [0x41, 0x42])
    }

    @Test func rejectsAFrameWithABrokenBodyCrc() {
        var parser = DumplStreamParser()
        var bytes = frame(cmdSet: 6, cmdId: 114, seq: 5, payload: [1, 2, 3, 4])
        bytes[bytes.count - 1] ^= 0xFF
        #expect(parser.feed(bytes).isEmpty)
    }

    @Test func doesNotGrowWithoutBoundOnPureNoise() {
        var parser = DumplStreamParser()
        for _ in 0..<40 {
            let noise = (0..<4096).map { _ in UInt8.random(in: 0...255) }
            _ = parser.feed(noise)
        }
        // A frame fed after the noise still parses, which is only true if the
        // buffer was trimmed rather than left to accumulate.
        let good = frame(cmdSet: 6, cmdId: 114, seq: 77)
        let out = parser.feed(good)
        #expect(out.contains(good))
    }
}
