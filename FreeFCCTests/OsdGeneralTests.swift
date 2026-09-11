// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Andrea Piani. https://www.andreapiani.com
// FreeFCC for iOS. Free for noncommercial use only. See LICENSE and NOTICE.md.
// Attribution required; do not present this work as your own.
//

import Testing
@testable import FreeFCC

struct OsdGeneralTests {
    // Wire velocities are signed little-endian values in tenths of m/s.
    // Literal fixtures catch overflow before conversion, wrong signedness,
    // incorrect vector magnitude and incorrect conversion to km/h.
    @Test(arguments: [
        ([UInt8](arrayLiteral: 0, 0, 0, 0), 0.0),
        ([UInt8](arrayLiteral: 30, 0, 40, 0), 18.0),
        ([UInt8](arrayLiteral: 0xE2, 0xFF, 40, 0), 18.0),
        ([UInt8](arrayLiteral: 181, 0, 0, 0), 65.16),
        ([UInt8](arrayLiteral: 182, 0, 0, 0), 65.52),
        ([UInt8](arrayLiteral: 0, 0, 0x4A, 0xFF), 65.52),
        ([UInt8](arrayLiteral: 200, 0, 150, 0), 90.0),
        ([UInt8](arrayLiteral: 0xFF, 0x7F, 0, 0), 11796.12),
        ([UInt8](arrayLiteral: 0, 0x80, 0, 0), 11796.48),
        ([UInt8](arrayLiteral: 0, 0x80, 0, 0x80), 16682.7420)
    ])
    func horizontalSpeed(velocityBytes: [UInt8], expectedKmh: Double) throws {
        let payload = [UInt8](repeating: 0, count: 18) + velocityBytes
        let speed = try #require(OsdGeneral.horizontalKmh(payload))
        #expect(abs(speed - expectedKmh) < 0.0001)
    }

    @Test func truncatedVelocityIsUnavailable() {
        for length in 0..<22 {
            #expect(OsdGeneral.horizontalKmh([UInt8](repeating: 0, count: length)) == nil)
        }
    }
}
