import Foundation

/// The two framings a DJI controller has been observed to accept on a mobile
/// link. Which one your hardware wants is decided by the controller firmware,
/// not by the operating system, so the app can sweep both.
enum Framing: String, Sendable, CaseIterable, Identifiable {
    /// DUMPL frame wrapped in the 8-byte RCLink envelope. What the Android
    /// build sends over the AOA pipe, and the first thing to try over MFi.
    case rclink
    /// Bare DUMPL frame, no envelope. What the Android build sends when it is
    /// plugged straight into the aircraft's USB-C port.
    case raw

    var id: String { rawValue }

    var label: String {
        switch self {
        case .rclink: return "RCLink"
        case .raw: return "Raw DUML"
        }
    }
}

/// RCLink envelope, the 8-byte header the controller's mobile-link parser
/// expects in front of every DUMPL frame.
///
///     [0] 0x55      magic byte 1
///     [1] 0xCC      magic byte 2 (RCLink header, not DUMPL 0x55-only)
///     [2] 0x49      route byte 1 ('I')
///     [3] 0x57      route byte 2 ('W')
///     [4-7]         payload length, uint32 LE, of the inner DUMPL frame
///     [8...]        DUMPL frame bytes (starts with 0x55)
enum RCLink {

    /// Route bytes used until the controller tells us otherwise.
    static let defaultRoute: [UInt8] = [0x49, 0x57]

    /// Envelope header length in bytes.
    static let headerLength = 8

    /// Wraps a bare DUMPL frame in the RCLink envelope.
    static func wrap(_ dumplFrame: [UInt8], route: [UInt8] = defaultRoute) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(headerLength + dumplFrame.count)
        out.append(0x55)
        out.append(0xCC)
        out.append(route.count > 0 ? route[0] : 0x49)
        out.append(route.count > 1 ? route[1] : 0x57)
        let len = UInt32(dumplFrame.count)
        out.append(UInt8(len & 0xFF))
        out.append(UInt8((len >> 8) & 0xFF))
        out.append(UInt8((len >> 16) & 0xFF))
        out.append(UInt8((len >> 24) & 0xFF))
        out.append(contentsOf: dumplFrame)
        return out
    }

    /// Applies the chosen framing to a bare DUMPL frame.
    static func encode(_ dumplFrame: [UInt8], framing: Framing, route: [UInt8] = defaultRoute) -> [UInt8] {
        switch framing {
        case .rclink: return wrap(dumplFrame, route: route)
        case .raw: return dumplFrame
        }
    }
}

/// Incremental parser for the inbound byte stream.
///
/// The Android build reads whole USB packets and assumes each read starts on a
/// frame boundary. An MFi stream gives no such guarantee: bytes arrive in
/// arbitrary chunks, so this resynchronises on every byte and only emits
/// frames whose header CRC-8 and body CRC-16 both check out. Anything that
/// fails is dropped one byte at a time until the stream lines up again.
struct DumplStreamParser {

    /// Route bytes seen on the last RCLink envelope, if any.
    private(set) var lastRoute: [UInt8]?

    /// Largest RCLink payload treated as plausible. Anything longer is noise.
    private let maxEnvelopePayload = 8192

    private var buffer = [UInt8]()

    init() {}

    /// Feeds new bytes and returns every complete DUMPL frame found.
    mutating func feed(_ bytes: [UInt8]) -> [[UInt8]] {
        buffer.append(contentsOf: bytes)
        var frames = [[UInt8]]()

        var index = 0
        scan: while index < buffer.count {
            let remaining = buffer.count - index

            guard buffer[index] == 0x55 else {
                index += 1
                continue
            }

            // RCLink envelope
            if remaining >= 2, buffer[index + 1] == 0xCC {
                guard remaining >= RCLink.headerLength else { break scan }
                let len = Int(buffer[index + 4])
                    | (Int(buffer[index + 5]) << 8)
                    | (Int(buffer[index + 6]) << 16)
                    | (Int(buffer[index + 7]) << 24)
                guard len > 0, len <= maxEnvelopePayload else {
                    index += 1
                    continue
                }
                guard remaining >= RCLink.headerLength + len else { break scan }
                lastRoute = [buffer[index + 2], buffer[index + 3]]
                let inner = Array(buffer[(index + RCLink.headerLength)..<(index + RCLink.headerLength + len)])
                // The envelope carries one or more DUMPL frames; parse them out.
                frames.append(contentsOf: Self.splitDumplFrames(inner))
                index += RCLink.headerLength + len
                continue
            }

            // Bare DUMPL frame
            guard remaining >= 4 else { break scan }
            let length = Int(buffer[index + 1]) | (Int(buffer[index + 2] & 0x03) << 8)
            guard length >= 13, length <= DumplBuilder.maxFrameLength else {
                index += 1
                continue
            }
            let header = [buffer[index], buffer[index + 1], buffer[index + 2]]
            guard DumplBuilder.crc8(header, from: 0, to: 3) == buffer[index + 3] else {
                index += 1
                continue
            }
            guard remaining >= length else { break scan }
            let frame = Array(buffer[index..<(index + length)])
            guard DumplBuilder.verifyCrc16(frame) else {
                index += 1
                continue
            }
            frames.append(frame)
            index += length
        }

        if index > 0 {
            buffer.removeFirst(index)
        }
        // A stream that never lines up must not grow without bound.
        if buffer.count > 64 * 1024 {
            buffer.removeFirst(buffer.count - 16 * 1024)
        }
        return frames
    }

    /// Pulls the DUMPL frames out of one RCLink payload.
    static func splitDumplFrames(_ payload: [UInt8]) -> [[UInt8]] {
        var out = [[UInt8]]()
        var i = 0
        while i + 13 <= payload.count {
            guard payload[i] == 0x55 else { i += 1; continue }
            let length = Int(payload[i + 1]) | (Int(payload[i + 2] & 0x03) << 8)
            guard length >= 13, i + length <= payload.count else { i += 1; continue }
            let frame = Array(payload[i..<(i + length)])
            guard DumplBuilder.verifyCrc16(frame) else { i += 1; continue }
            out.append(frame)
            i += length
        }
        return out
    }
}

/// A decoded inbound DUMPL frame.
struct DumplResponse: Sendable {
    var sender: Int
    var dst: Int
    var seq: Int
    var cmdType: Int
    var cmdSet: Int
    var cmdId: Int
    var payload: [UInt8]

    /// True when bit 7 of the command type marks this as a response.
    var isResponse: Bool { (cmdType & 0x80) != 0 }

    /// Key used to match a response against the command that asked for it.
    var ackKey: Int { (cmdSet << 8) | cmdId }

    init?(frame: [UInt8]) {
        guard frame.count >= 13, frame[0] == 0x55 else { return nil }
        sender = Int(frame[4])
        dst = Int(frame[5])
        seq = Int(frame[6]) | (Int(frame[7]) << 8)
        cmdType = Int(frame[8])
        cmdSet = Int(frame[9])
        cmdId = Int(frame[10])
        payload = Array(frame[11..<(frame.count - 2)])
    }
}
