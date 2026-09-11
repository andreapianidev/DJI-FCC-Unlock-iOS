// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Andrea Piani. https://www.andreapiani.com
// FreeFCC for iOS. Free for noncommercial use only. See LICENSE and NOTICE.md.
// Attribution required; do not present this work as your own.
//

import Testing
@testable import FreeFCC

struct ParamHashTests {
    // max_height is the hash the Neo echoes; the control globals are the ones
    // the v1.3 to v1.7 boost wrote; the Sport and Normal block hashes are the
    // live Mini 1 values published by DJI-Link.
    @Test(arguments: [
        ("g_config.flying_limit.max_height_0", 0x0371238a),
        ("g_config.control.atti_range_0", 0x9da51eee),
        ("g_config.control.horiz_vel_atti_range_0", 0xde0fff00),
        ("g_config.mode_normal_cfg.tilt_atti_range_0", 0x95544807),
        ("mode_sport_cfg_tilt_atti_range_0", 0x3bf365ce),
        ("mode_sport_cfg_vert_vel_up_0", 0xac320b0d),
    ] as [(String, UInt32)])
    func knownHashes(name: String, hash: UInt32) {
        #expect(ParamHash.of(name) == hash)
    }
}

struct ParamEchoTests {
    @Test func maxHeightEchoFromHardware() throws {
        // RSP 03→02 set=03 id=F9 [00 8A 23 71 03 78 00], Neo log of 7 Sep 2026.
        let echo = try #require(ParamEcho([0x00, 0x8A, 0x23, 0x71, 0x03, 0x78, 0x00]))
        #expect(echo.status == 0)
        #expect(echo.hash == 0x0371238a)
        #expect(echo.value == [0x78, 0x00])
        #expect(echo.float == nil)
    }

    @Test func bareReplyIsNotAnEcho() {
        // What every v1.3 to v1.7 boost write got back: status only.
        #expect(ParamEcho([0x00]) == nil)
    }

    @Test func floatValue() throws {
        let echo = try #require(ParamEcho([0x00, 0xCE, 0x65, 0xF3, 0x3B] + SportBoost.f32(30)))
        #expect(echo.hash == 0x3bf365ce)
        #expect(echo.float == 30)
    }
}

struct SportBoostTests {
    @Test func tiltTargetStepsOverStockAndStopsAtTheCeiling() {
        #expect(SportBoost.tiltTarget(stock: 25) == 35)
        #expect(SportBoost.tiltTarget(stock: 35) == 40)
        #expect(SportBoost.tiltTarget(stock: 40) == nil)
        #expect(SportBoost.tiltTarget(stock: 45) == nil)
    }

    @Test func unknownOrImplausibleStockFallsBack() {
        #expect(SportBoost.tiltTarget(stock: nil) == SportBoost.fallbackTilt)
        #expect(SportBoost.tiltTarget(stock: 0) == SportBoost.fallbackTilt)
        #expect(SportBoost.tiltTarget(stock: .nan) == SportBoost.fallbackTilt)
    }

    @Test func writesOnlyTheSportBlock() {
        #expect(SportBoost.params.allSatisfy { $0.name.contains("mode_sport_cfg") })
        #expect(Set(SportBoost.params.map(\.hash)).count == SportBoost.params.count)
    }

    @Test func hashGoesOnTheWireLittleEndian() throws {
        let tilt = try #require(SportBoost.params.first)
        #expect(tilt.hashLE == [0xCE, 0x65, 0xF3, 0x3B])
    }
}
