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
        FlycParam(name: "flying_limit.max_height", hash: 0x0371238a,
                  note: "Self-check: should read 500 after an FCC apply"),
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
