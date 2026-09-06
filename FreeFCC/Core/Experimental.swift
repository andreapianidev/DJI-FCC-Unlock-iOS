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
/// self-check: its value is known to be 500 after an FCC apply, so a correct
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
                  note: "The aircraft height ceiling. Should read 500 after apply"),
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

/// The staged Sport-speed boost (issue #3).
///
/// The Neo caps horizontal speed at 8 m/s (28.8 km/h) and ascent at 3 m/s from
/// the RC, while it reaches ~16 m/s in manual with the goggles. Horizontal speed
/// is set by the attitude range (max tilt), capped by atti_limit; ascent by
/// vert_up_vel. This writes modest values, safe across encodings: as integer
/// degrees they are an aggressive-but-flyable tilt, and if the parameter is a
/// different unit or width the write is a no-op rather than an extreme. The
/// flight controller also clamps out-of-range writes to its own maximum, proven
/// when max_height 500 stored 120. Flight-safety-critical: test low and slow,
/// and power-cycle to reset.
enum SpeedBoost {
    static let writeByHash = 0xF9

    /// A 32-bit float, little-endian, as the config table stores these
    /// attitude and velocity parameters. The v1.3 integer writes were ignored
    /// on hardware (full-stick Sport still capped at the normal speed), which
    /// is the signature of the wrong width: these parameters are floats.
    private static func f32(_ v: Float) -> [UInt8] {
        withUnsafeBytes(of: v.bitPattern.littleEndian) { Array($0) }
    }

    static let params: [GateParam] = [
        GateParam(name: "control.atti_limit_0", hash: 0x9f9646e9, value: f32(45),
                  note: "raise the cap on atti_range first (degrees)"),
        GateParam(name: "control.atti_range_0", hash: 0x9da51eee, value: f32(40),
                  note: "max tilt in GPS/Sport, drives horizontal speed (degrees)"),
        GateParam(name: "control.horiz_vel_atti_range_0", hash: 0xde0fff00, value: f32(40),
                  note: "horizontal-velocity attitude range (degrees)"),
        GateParam(name: "control.vert_up_vel_0", hash: 0x3d45f2c8, value: f32(6),
                  note: "max ascent speed m/s, was ~3"),
        GateParam(name: "control.vert_down_vel_0", hash: 0x70dbcaa7, value: f32(6),
                  note: "max descent speed m/s"),
    ]
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
        let ms = (Double(vx * vx) + Double(vy * vy)).squareRoot() * 0.1
        return ms * 3.6
    }

    static func heightMeters(_ payload: [UInt8]) -> Double? {
        guard let h = i16(payload, 16) else { return nil }
        return Double(h) * 0.1
    }

    static func flightMode(_ payload: [UInt8]) -> String {
        // The mode byte sits after longitude(8) latitude(8) height(2) vgx/vgy/vgz(6)
        // pitch/roll/yaw(6) ctrl_info(1) => offset 31.
        let off = 31
        guard payload.count > off else { return "?" }
        let names: [Int: String] = [
            0x00: "Manual", 0x01: "Atti", 0x03: "Atti_Hover", 0x04: "Hover",
            0x06: "GPS_Atti (normal)", 0x0a: "AssistedTakeoff", 0x0b: "AutoTakeoff",
            0x0c: "AutoLanding", 0x0f: "GoHome", 0x11: "Joystick",
            0x17: "Atti_Limited", 0x18: "GPS_Atti_Limited",
        ]
        return names[Int(payload[off])] ?? String(format: "mode 0x%02X", payload[off])
    }
}
