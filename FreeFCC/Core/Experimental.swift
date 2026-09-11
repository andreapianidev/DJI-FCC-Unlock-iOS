// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Andrea Piani. https://www.andreapiani.com
// FreeFCC for iOS. Free for noncommercial use only. See LICENSE and NOTICE.md.
// Attribution required; do not present this work as your own.
//

import Foundation

/// A flight-controller parameter, addressed by the hash of its name, as the
/// DUML config table exposes it.
///
/// These are read and written with the same by-hash commands the FCC profile
/// already uses (0xF7 get info, 0xF8 read value, 0xF9 write value), on the
/// FLYCONTROLLER command set. The hashes come from the public
/// dji-firmware-tools parameter tables.
struct FlycParam: Sendable, Identifiable {
    let name: String
    let hash: UInt32
    /// A one-line note on what the parameter governs and why it is here.
    let note: String

    var id: UInt32 { hash }

    /// Hash as it goes on the wire: little-endian, 4 bytes.
    var hashLE: [UInt8] {
        [UInt8(hash & 0xFF), UInt8((hash >> 8) & 0xFF), UInt8((hash >> 16) & 0xFF), UInt8((hash >> 24) & 0xFF)]
    }
}

/// The parameters the speed experiment reads. max_height is first as a
/// self-check: the tested Neo reports 120 even after requesting 500, so a correct
/// read of it proves the read path and the hash encoding before any attitude
/// parameter is trusted.
enum SpeedExperiment {
    static let flycSet = 0x03
    static let getInfoByHash = 0xF7
    static let readValueByHash = 0xF8
    static let writeValueByHash = 0xF9

    static let params: [FlycParam] = [
        // Altitude and geo limits, the reverse-engineering targets for 500m.
        FlycParam(name: "flying_limit.max_height", hash: 0x0371238a,
                  note: "The aircraft height ceiling. Tested Neo reports 120 after requesting 500"),
        FlycParam(name: "flying_limit.max_radius", hash: 0x425c0a94,
                  note: "The distance ceiling"),
        FlycParam(name: "advanced_function.height_limit_enabled", hash: 0xae52d19a,
                  note: "Whether the height limit is enforced"),
        FlycParam(name: "novice_cfg.max_height", hash: 0xd9ab9f79,
                  note: "Beginner-mode height ceiling"),
        FlycParam(name: "airport_limit_cfg.cfg_disable_airport_fly_limit", hash: 0x8fb32a2d,
                  note: "Whether airport/NFZ limits are disabled"),
        // Speed limits.
        FlycParam(name: "control.horiz_vel_atti_range", hash: 0xde0fff00,
                  note: "Attitude range that caps horizontal speed"),
        FlycParam(name: "control.atti_range", hash: 0x9da51eee,
                  note: "General attitude range"),
        FlycParam(name: "control.horiz_emergency_brake_tilt_max", hash: 0x3d833d3a,
                  note: "Max tilt during emergency braking")
    ]

    /// Type ids from the DUML config table. Determines how min/max/def and the
    /// value are encoded in the reply.
    static func typeName(_ typeId: Int) -> String {
        switch typeId {
        case 0...3, 10: return "uint"
        case 4...7: return "int"
        case 8, 9: return "float"
        default: return "type \(typeId)"
        }
    }

    static func isFloat(_ typeId: Int) -> Bool { typeId == 8 || typeId == 9 }
    static func isSigned(_ typeId: Int) -> Bool { typeId >= 4 && typeId <= 7 }
}

/// Parsed result of a Get Param Info By Hash (0xF7) reply.
///
/// The reply carries the parameter's type and size and, crucially, the min,
/// max and default the firmware itself enforces. Those bounds are what make a
/// later write safe: the experiment never has to guess a ceiling, it reads the
/// one the flight controller already honours.
struct ParamInfo: Sendable {
    var status: Int
    var typeId: Int
    var size: Int
    var minRaw: [UInt8]
    var maxRaw: [UInt8]
    var defRaw: [UInt8]

    /// Decodes the info reply payload (status + type + size + attribute + three
    /// 4-byte limit fields), or nil if it is too short or the status is not OK.
    init?(payload: [UInt8]) {
        guard payload.count >= 7 else { return nil }
        status = Int(payload[0])
        typeId = Int(payload[1]) | (Int(payload[2]) << 8)
        size = Int(payload[3]) | (Int(payload[4]) << 8)
        guard status == 0, payload.count >= 19 else {
            // Still record status so a non-zero one is visible.
            minRaw = []; maxRaw = []; defRaw = []
            if status == 0 { return nil }
            return
        }
        minRaw = Array(payload[7..<11])
        maxRaw = Array(payload[11..<15])
        defRaw = Array(payload[15..<19])
    }

    private func number(_ raw: [UInt8]) -> String {
        guard raw.count == 4 else { return "-" }
        let u = UInt32(raw[0]) | (UInt32(raw[1]) << 8) | (UInt32(raw[2]) << 16) | (UInt32(raw[3]) << 24)
        if SpeedExperiment.isFloat(typeId) {
            return String(format: "%.3f", Float(bitPattern: u))
        }
        if SpeedExperiment.isSigned(typeId) {
            return String(Int32(bitPattern: u))
        }
        return String(u)
    }

    var minText: String { number(minRaw) }
    var maxText: String { number(maxRaw) }
    var defText: String { number(defRaw) }
}

/// One flight-controller limit parameter the altitude-gate probe writes, then
/// reads back from the write's own `0xF9` reply (this firmware answers the write
/// verb with `status + hash + stored value`, but not the read verbs 0xF7/0xF8).
///
/// Altitude, distance and geo limits only. No control or attitude parameter is
/// ever in this list: those govern how the aircraft flies and stay read-only
/// until a working read exists (issue #3).
struct GateParam: Sendable {
    let name: String
    let hash: UInt32
    /// Value to write, little-endian, its own width (u8 for a flag, u16 for a
    /// height, matching what the FCC profile already uses for max_height).
    let value: [UInt8]
    let note: String

    var hashLE: [UInt8] {
        [UInt8(hash & 0xFF), UInt8((hash >> 8) & 0xFF), UInt8((hash >> 16) & 0xFF), UInt8((hash >> 24) & 0xFF)]
    }
}

/// The 500m altitude-gate hunt (issue #1).
///
/// Writing `flying_limit.max_height` to 500 is acknowledged but the drone stores
/// 120, so the 120m ceiling is gated by another parameter. This probe writes one
/// limit candidate at a time and reads the value the drone actually stored, so we
/// can bisect to the parameter that opens the DJI Fly slider past 120.
///
/// Hashes are computed with DJI's own name-hash (verified: the five known params
/// below reproduce their documented hashes bit for bit), so the generated
/// candidates address real parameters when they exist and are simply ignored
/// when they do not.
enum AltitudeGate {
    static let writeByHash = 0xF9

    private static func u16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }

    static let candidates: [GateParam] = [
        // Verified hashes (reproduce the documented values).
        GateParam(name: "flying_limit.max_height_0", hash: 0x0371238a, value: u16(500),
                  note: "the ceiling the app already writes; the drone clamps it to 120"),
        GateParam(name: "advanced_function.height_limit_enabled_0", hash: 0xae52d19a, value: [0x00],
                  note: "turn OFF height-limit enforcement (app currently writes 1)"),
        GateParam(name: "novice_cfg.max_height_0", hash: 0xd9ab9f79, value: u16(500),
                  note: "beginner-mode ceiling"),
        GateParam(name: "airport_limit_cfg.cfg_disable_airport_fly_limit_0", hash: 0x8fb32a2d, value: [0x01],
                  note: "disable airport/NFZ limits"),
        // Generated candidates for the gate (real hashes, may or may not exist here).
        GateParam(name: "flying_limit.height_limit_num_0", hash: 0x11ce86a4, value: u16(500),
                  note: "candidate: a separate height-limit value"),
        GateParam(name: "flying_limit.height_limit_0", hash: 0x85ad07a3, value: u16(500),
                  note: "candidate: height limit"),
        GateParam(name: "flying_limit.max_height_type_0", hash: 0xa61867e2, value: [0x01],
                  note: "candidate: height-limit type/zone selector"),
        GateParam(name: "flying_limit.enable_flying_limit_0", hash: 0x510882c8, value: [0x00],
                  note: "candidate: disable the flying limit entirely"),
        GateParam(name: "flying_limit.limit_gps_not_ready_max_height_0", hash: 0x642acdc9, value: u16(500),
                  note: "candidate: GPS-not-ready height ceiling"),
    ]
}

/// Read-only probe over `0xFB` (Read Params By Hash), the read verb this
/// firmware may still answer after 0xF7/0xF8 came back silent. Request format
/// from the dji-firmware-tools dissector: one flag byte then a 4-byte name hash.
/// Reading is the unblock for both goals: the geo/authority values for the 500m
/// gate (#1) and the attitude ranges plus their firmware bounds for the 60 km/h
/// Sport target (#3), without writing a control parameter.
///
/// All hashes here are the real dji-firmware-tools values (verified: the known
/// ones reproduce their documented hashes).
enum ConfigRead {
    static let readMultiByHash = 0xFB

    static let params: [FlycParam] = [
        FlycParam(name: "flying_limit.max_height_0", hash: 0x0371238a,
                  note: "altitude ceiling, self-check (expect 120)"),
        FlycParam(name: "flying_limit.max_radius_0", hash: 0x425c0a94,
                  note: "distance ceiling"),
        FlycParam(name: "api_entry_cfg.authority_level_0", hash: 0x7b24ba4b,
                  note: "SDK/API authority level, the 500m-gate candidate"),
        FlycParam(name: "api_entry_cfg.height_data_type_0", hash: 0x96a0a2cf,
                  note: "height data type"),
        FlycParam(name: "control.atti_range_0", hash: 0x9da51eee,
                  note: "attitude range, caps Sport speed"),
        FlycParam(name: "control.horiz_vel_atti_range_0", hash: 0xde0fff00,
                  note: "horizontal-velocity attitude range"),
        FlycParam(name: "control.atti_limit_0", hash: 0x9f9646e9,
                  note: "caps the atti_range max value"),
        FlycParam(name: "control.horiz_emergency_brake_tilt_max_0", hash: 0x3d833d3a,
                  note: "emergency-brake tilt max"),
    ]
}

/// DJI's flight-controller parameter-name hash, the one DJI Fly and
/// dji-firmware-tools (`flyc_parameter_compute_hash`) use. The whole name is
/// hashed, `g_config.` prefix and `_0` suffix included:
/// `g_config.flying_limit.max_height_0` gives 0x0371238a, the hash the Neo
/// echoes on every apply.
enum ParamHash {
    static func of(_ name: String) -> UInt32 {
        var h: UInt64 = 0
        // DJI hashes the GBK bytes; for the ASCII names used here GBK is UTF-8.
        for byte in name.utf8 {
            h = (((h & 0xFFFF_FFFF) << 8) + UInt64(byte)) % 0xFFFF_FFFB
        }
        return UInt32(h)
    }
}

/// A by-hash config reply decoded: status(1) + hash(4) + stored value.
///
/// On the Neo a parameter that exists answers the 0xF9 write in this full form
/// (max_height: `00 8A 23 71 03 78 00`). A hash that is not in the table gets a
/// bare `[00]`: status only, nothing stored. That difference is the only
/// existence test this firmware offers, since 0xF7/0xF8 never answer.
struct ParamEcho: Sendable, Equatable {
    let status: UInt8
    let hash: UInt32
    let value: [UInt8]

    init?(_ payload: [UInt8]) {
        guard payload.count >= 5 else { return nil }
        status = payload[0]
        hash = UInt32(payload[1]) | (UInt32(payload[2]) << 8) | (UInt32(payload[3]) << 16) | (UInt32(payload[4]) << 24)
        value = Array(payload.dropFirst(5))
    }

    /// The stored value as a little-endian float32, when it is 4 bytes wide.
    var float: Float? {
        guard value.count == 4 else { return nil }
        let bits = UInt32(value[0]) | (UInt32(value[1]) << 8) | (UInt32(value[2]) << 16) | (UInt32(value[3]) << 24)
        return Float(bitPattern: bits)
    }
}

/// The Sport-speed boost, second attempt (issue #3).
///
/// v1.3 to v1.7 wrote `g_config.control.atti_range`, `horiz_vel_atti_range`,
/// `atti_limit`, `vert_up_vel` and `vert_down_vel`. On the Neo every one of
/// those writes got a bare `[00]`, the reply of a hash that is not in the
/// table, so nothing was stored and Sport stayed at 28.8 km/h. They are
/// Phantom-era globals. Mavic-generation firmware (the Mini 1 and Mavic 3
/// dumps) keeps one config block per flight mode, and Sport top speed is that
/// block's max tilt, `tilt_atti_range`, a float in degrees. Stock Sport tilt is
/// 30 on the Mini 1 (range 5 to 40) and 35 on the Mavic 3 (range 10 to 35); the
/// Neo's is unknown.
///
/// Both published spellings of each name are tried, since the dumps list them
/// as aliases and the live one differs by model (the Mini 1 answers on the
/// underscore form for tilt). An absent hash is a no-op.
///
/// These block parameters persist on the Mini 1 (attribute RW+EE), so unlike
/// the FCC and altitude writes they may survive a power cycle. Restore Sport
/// Defaults resets them with 0xFA.
enum SportBoost {
    static let writeByHash = 0xF9
    /// Reset Param To Default By Hash (`DataFlycResetParams` in the DJI SDK).
    static let resetByHash = 0xFA

    /// The highest tilt this app will ever request, in degrees.
    static let maxTilt: Float = 40
    /// How far one boost raises the tilt over the stock value.
    static let tiltStep: Float = 10
    /// The tilt written when the stock value could not be read: the Mavic 3
    /// factory Sport tilt, inside every published range.
    static let fallbackTilt: Float = 35
    /// Stick-to-tilt scaling at full stick. 1.0 is the top of every published
    /// range, so full stick asks for the whole tilt instead of about 95% of it.
    static let rcScale: Float = 1.0

    enum Kind: Sendable { case tilt, rcScale }

    struct Param: Sendable {
        let name: String
        let kind: Kind

        var hash: UInt32 { ParamHash.of(name) }

        var hashLE: [UInt8] {
            [UInt8(hash & 0xFF), UInt8((hash >> 8) & 0xFF), UInt8((hash >> 16) & 0xFF), UInt8((hash >> 24) & 0xFF)]
        }
    }

    static let params: [Param] = [
        Param(name: "mode_sport_cfg_tilt_atti_range_0", kind: .tilt),
        Param(name: "g_config.mode_sport_cfg.tilt_atti_range_0", kind: .tilt),
        Param(name: "g_config.mode_sport_cfg.rc_scale_0", kind: .rcScale),
        Param(name: "mode_sport_cfg_rc_scale_0", kind: .rcScale),
    ]

    /// Tilt to write, given the stock tilt the 0xFA reset reported. An unknown
    /// or implausible stock falls back to `fallbackTilt`. Nil means there is
    /// nothing to raise: stock is already at or above the app's ceiling.
    static func tiltTarget(stock: Float?) -> Float? {
        guard let stock, stock >= 5, stock <= 60 else { return fallbackTilt }
        guard stock < maxTilt else { return nil }
        return min(stock + tiltStep, maxTilt)
    }

    /// A 32-bit float, little-endian, as the config table stores these.
    static func f32(_ v: Float) -> [UInt8] {
        withUnsafeBytes(of: v.bitPattern.littleEndian) { Array($0) }
    }
}

/// Decoder for the FLYCONTROLLER OSD General push (set 0x03, id 0x43), the frame
/// that carries live height, ground speed and flight mode. Offsets follow the
/// dji-firmware-tools dissector: relative_height int16 at 16 (0.1 m), Vgx/Vgy/Vgz
/// int16 at 18/20/22 (0.1 m/s), flight-mode byte after the attitude fields.
enum OsdGeneral {
    static func i16(_ b: [UInt8], _ off: Int) -> Int16? {
        guard b.count >= off + 2 else { return nil }
        return Int16(bitPattern: UInt16(b[off]) | (UInt16(b[off + 1]) << 8))
    }

    /// Horizontal ground speed in km/h from Vgx and Vgy.
    static func horizontalKmh(_ payload: [UInt8]) -> Double? {
        guard let vx = i16(payload, 18), let vy = i16(payload, 20) else { return nil }
        // Convert before multiplying: Int16 overflows at |component| >= 182.
        let x = Double(vx)
        let y = Double(vy)
        let ms = (x * x + y * y).squareRoot() * 0.1
        return ms * 3.6
    }

    static func heightMeters(_ payload: [UInt8]) -> Double? {
        guard let h = i16(payload, 16) else { return nil }
        return Double(h) * 0.1
    }

    /// Lean angle in degrees from pitch and roll (int16 at 24/26, 0.1 degree),
    /// the size of the tilt whichever way the aircraft flies.
    static func tiltDegrees(_ payload: [UInt8]) -> Double? {
        guard let p = i16(payload, 24), let r = i16(payload, 26) else { return nil }
        let pitch = Double(p) * 0.1
        let roll = Double(r) * 0.1
        return (pitch * pitch + roll * roll).squareRoot()
    }

    static func flightMode(_ payload: [UInt8]) -> String {
        // After longitude(8) latitude(8) height(2) vgx/vgy/vgz(6) pitch/roll/yaw(6)
        // comes one byte, offset 30, that the dissector reads as ctrl_info and
        // as flyc_state (its low 7 bits). Up to v1.7.1 this read offset 31,
        // the next field.
        let off = 30
        guard payload.count > off else { return "?" }
        let state = Int(payload[off] & 0x7F)
        let names: [Int: String] = [
            0x00: "Manual", 0x01: "Atti", 0x03: "Atti_Hover", 0x04: "Hover",
            0x06: "GPS_Atti (normal)", 0x0a: "AssistedTakeoff", 0x0b: "AutoTakeoff",
            0x0c: "AutoLanding", 0x0f: "GoHome", 0x11: "Joystick",
            0x17: "Atti_Limited", 0x18: "GPS_Atti_Limited",
        ]
        return names[state] ?? String(format: "mode 0x%02X", state)
    }
}
