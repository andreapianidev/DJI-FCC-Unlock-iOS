// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Andrea Piani. https://www.andreapiani.com
// FreeFCC for iOS. Free for noncommercial use only. See LICENSE and NOTICE.md.
// Attribution required; do not present this work as your own.
//

import Foundation

/// One command frame as written in a profile JSON file.
struct ProfileFrame: Codable, Sendable, Identifiable {
    /// Command set (16 = service mode, 6 = radio, 3 = flight controller).
    let cmdSet: Int
    /// Command ID within the set.
    let cmdId: Int
    /// Destination device.
    let dst: Int
    /// Payload bytes, written as a hex string in the file.
    let payload: [UInt8]
    /// Plain English description of what the frame does.
    let note: String

    var id: String { "\(cmdSet).\(cmdId).\(dst).\(payloadHex)" }

    var payloadHex: String { payload.map { String(format: "%02X", $0) }.joined() }

    enum CodingKeys: String, CodingKey {
        case cmdSet = "s"
        case cmdId = "i"
        case dst = "d"
        case payload = "p"
        case note
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cmdSet = try c.decode(Int.self, forKey: .cmdSet)
        cmdId = try c.decode(Int.self, forKey: .cmdId)
        dst = try c.decode(Int.self, forKey: .dst)
        let hex = try c.decodeIfPresent(String.self, forKey: .payload) ?? ""
        payload = try ProfileLoader.hexToBytes(hex)
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(cmdSet, forKey: .cmdSet)
        try c.encode(cmdId, forKey: .cmdId)
        try c.encode(dst, forKey: .dst)
        try c.encode(payloadHex.lowercased(), forKey: .payload)
        try c.encode(note, forKey: .note)
    }
}

/// A DUMPL command profile: the frames to send plus the timing they need.
struct Profile: Codable, Sendable {
    let name: String
    let summary: String
    let source: String
    /// Sender byte the profile was captured with.
    let sender: Int
    let cmdType: Int
    let rounds: Int
    let interFrameDelayMs: Int
    let interRoundDelayMs: Int
    let readWindowMs: Int
    let repeatIntervalMs: Int
    let frames: [ProfileFrame]

    enum CodingKeys: String, CodingKey {
        case name
        case summary = "description"
        case source
        case sender
        case cmdType = "cmd_type"
        case rounds
        case interFrameDelayMs = "inter_frame_delay_ms"
        case interRoundDelayMs = "inter_round_delay_ms"
        case readWindowMs = "read_window_ms"
        case repeatIntervalMs = "repeat_interval_ms"
        case frames
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Profile"
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        sender = try c.decode(Int.self, forKey: .sender)
        cmdType = try c.decode(Int.self, forKey: .cmdType)
        rounds = try c.decode(Int.self, forKey: .rounds)
        interFrameDelayMs = try c.decodeIfPresent(Int.self, forKey: .interFrameDelayMs) ?? 0
        interRoundDelayMs = try c.decodeIfPresent(Int.self, forKey: .interRoundDelayMs) ?? 0
        readWindowMs = try c.decodeIfPresent(Int.self, forKey: .readWindowMs) ?? 80
        repeatIntervalMs = try c.decodeIfPresent(Int.self, forKey: .repeatIntervalMs) ?? 8000
        frames = try c.decode([ProfileFrame].self, forKey: .frames)
    }

    /// Inter-frame delay as seconds, ready for `Thread.sleep`.
    var interFrameDelay: TimeInterval { Double(interFrameDelayMs) / 1000 }
    /// Inter-round delay as seconds.
    var interRoundDelay: TimeInterval { Double(interRoundDelayMs) / 1000 }
}

enum ProfileError: LocalizedError {
    case notFound(String)
    case badHex(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let name): return "Profile \(name) is not in the app bundle"
        case .badHex(let hex): return "Payload is not valid hex: \(hex)"
        }
    }
}

/// Loads DUMPL command profiles from the JSON files bundled with the app.
enum ProfileLoader {

    static let fccProfileName = "fcc"
    static let ceRestoreProfileName = "ce_restore"

    /// Reads and decodes a profile from `Resources/profiles/<name>.json`.
    static func load(_ name: String, bundle: Bundle = .main) throws -> Profile {
        guard let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "profiles")
            ?? bundle.url(forResource: name, withExtension: "json") else {
            throw ProfileError.notFound(name)
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Profile.self, from: data)
    }

    /// Builds a wire-ready DUML frame from a profile entry, taking the next
    /// sequence number from the global counter.
    static func buildFrame(_ frame: ProfileFrame, sender: Int, cmdType: Int) -> [UInt8] {
        DumplBuilder.buildFrame(
            DumplFrame(
                sender: sender,
                cmdType: cmdType,
                cmdSet: frame.cmdSet,
                cmdId: frame.cmdId,
                dst: frame.dst,
                payload: frame.payload
            )
        )
    }

    /// Parses a hex string, ignoring spaces and newlines.
    static func hexToBytes(_ hex: String) throws -> [UInt8] {
        let clean = hex.filter { !$0.isWhitespace }
        if clean.isEmpty { return [] }
        guard clean.count % 2 == 0 else { throw ProfileError.badHex(hex) }
        var out = [UInt8]()
        out.reserveCapacity(clean.count / 2)
        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2)
            guard let byte = UInt8(clean[index..<next], radix: 16) else {
                throw ProfileError.badHex(hex)
            }
            out.append(byte)
            index = next
        }
        return out
    }
}
