// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Andrea Piani. https://www.andreapiani.com
// FreeFCC for iOS. Free for noncommercial use only. See LICENSE and NOTICE.md.
// Attribution required; do not present this work as your own.
//

import ExternalAccessory
import Foundation
import Observation
import UIKit

/// Where the app is in the connect / apply / release cycle.
enum AppStatus: String, Sendable {
    case idle
    case disconnected
    case connecting
    case connected
    case applying
    case fccEnabled
    /// Every frame went out and nothing came back. Not the same as success,
    /// and not the same as failure either.
    case sentUnconfirmed
    case restoring
    case released
}

/// One self-contained attempt at switching the radio: a sender byte and a
/// framing, sent as a complete open-write-close pass of the profile.
struct CommandPath: Sendable, Equatable {
    var sender: Int
    var framing: Framing

    var label: String { String(format: "profile@%02X/%@", sender, framing.label) }
}

/// How much of the path space an apply should sweep.
enum FramingMode: String, Sendable, CaseIterable, Identifiable {
    case sweep
    case rclinkOnly
    case rawOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sweep: return "Sweep both"
        case .rclinkOnly: return "RCLink only"
        case .rawOnly: return "Raw DUML only"
        }
    }

    var framings: [Framing] {
        switch self {
        case .sweep: return [.rclink, .raw]
        case .rclinkOnly: return [.rclink]
        case .rawOnly: return [.raw]
        }
    }
}

/// Owns all app state and the whole business flow.
///
/// The connect side lives on the main actor because ExternalAccessory does.
/// The frame bursts live on a private serial queue and sleep with
/// `Thread.sleep`, because the profile only lands if the 21 frames fit inside
/// the service-mode window that frame 1 opens and frame 21 closes. At 30ms per
/// frame a pass runs about 0.65 seconds; scheduling those delays through the
/// cooperative pool would stretch them, and a stretched burst is exactly the
/// case where every write succeeds and the radio quietly stays on CE.
@MainActor
@Observable
final class FccController {

    // MARK: Tunables

    /// Sender byte from the captured sequence, device 2 index 4. The widest
    /// set of field reports come from builds using this.
    nonisolated static let senderCapture = 0x82
    /// Sender byte on network 0, what bootstrap and keepalive use.
    nonisolated static let senderNet0 = 0x02
    /// Sender byte for the single-command WLM radio switch.
    nonisolated static let senderWlm = 0xA2
    /// How long Connect keeps looking for the accessory.
    nonisolated static let connectTimeout: TimeInterval = 15

    // MARK: Observable state

    private(set) var status: AppStatus = .idle
    private(set) var message = ""
    private(set) var transportName = ""
    private(set) var transportKind = ""
    private(set) var isConnected = false
    private(set) var isFccEnabled = false
    private(set) var isBusy = false
    private(set) var busyProgress: Double = 0
    private(set) var logMessages: [String] = []
    private(set) var accessories: [AccessoryInfo] = []
    private(set) var detectedSerial = ""
    private(set) var winningPath: CommandPath?
    private(set) var profile: Profile?
    private(set) var protocolInUse = ""

    var autoFcc = false {
        didSet {
            guard autoFcc != oldValue else { return }
            defaults.set(autoFcc, forKey: Keys.autoFcc)
            log(autoFcc ? "Auto-FCC enabled" : "Auto-FCC disabled")
        }
    }

    /// Which MFi protocol to open, empty meaning let the ranking choose.
    ///
    /// Kept switchable at runtime because the ranking is an educated guess:
    /// logiclink reads like a command channel and video certainly is not one,
    /// but only the response counts settle it, and finding out should not
    /// cost a rebuild.
    var preferredProtocol: String = "" {
        didSet {
            guard preferredProtocol != oldValue else { return }
            defaults.set(preferredProtocol, forKey: Keys.preferredProtocol)
            log(preferredProtocol.isEmpty ? "Protocol set to auto" : "Protocol pinned to \(preferredProtocol)")
        }
    }

    var framingMode: FramingMode = .sweep {
        didSet {
            guard framingMode != oldValue else { return }
            defaults.set(framingMode.rawValue, forKey: Keys.framingMode)
            log("Framing set to \(framingMode.label)")
        }
    }

    // MARK: Private state

    private enum Keys {
        static let autoFcc = "auto_fcc"
        static let framingMode = "framing_mode"
        static let preferredProtocol = "preferred_protocol"
    }

    private let defaults = UserDefaults.standard
    private let engineQueue = DispatchQueue(label: "com.andreapiani.freefcc.engine", qos: .userInitiated)

    /// Shared with the engine queue, so it must not be plain stored state.
    private let transportBox = Protected<(any DumplTransport)?>(nil)
    private let ackKeys = Protected(Set<Int>())
    private let ackHits = Protected(0)
    /// Full inbound responses recorded during a capture window, keyed the same
    /// way as the ack watch. Counting responses says whether a command was
    /// heard; the payloads say what the answer actually was, which is what a
    /// Get command exists to return.
    private let captureKeys = Protected(Set<Int>())
    private let captured = Protected([(key: Int, payload: [UInt8])]())
    private let preferredPath = Protected(CommandPath(sender: FccController.senderCapture, framing: .rclink))
    private let repeatCancelled = Protected(true)
    /// Interfaces present before the cable went in, so the diff after it does
    /// is unambiguous.
    private let baselineInterfaces = Protected(Set<String>())
    /// Every inbound frame tallied by sender, destination and command, with a
    /// sample of the most recent payload, so the real conversation on the link
    /// can be read rather than guessed at.
    private let frameCensus = Protected([Int: (count: Int, sample: [UInt8])]())
    /// One Sport-block run at a time: a second tap would queue behind the
    /// first and land on a link that has gone cold by then.
    private let sportRunning = Protected(false)
    /// The Sport tilt the drone last echoed as stored, for the flight recorder
    /// to compare with the tilt actually flown.
    private let sportTiltStored = Protected<Float?>(nil)

    private var repeatTimer: DispatchSourceTimer?
    private var serialPollTask: Task<Void, Never>?

    // MARK: Lifecycle

    func start() {
        autoFcc = defaults.bool(forKey: Keys.autoFcc)
        if let raw = defaults.string(forKey: Keys.framingMode), let mode = FramingMode(rawValue: raw) {
            framingMode = mode
        }
        preferredProtocol = defaults.string(forKey: Keys.preferredProtocol) ?? ""
        DiagnosticLog.shared.startSession(header: [
            "FCC Unlock iOS \(AppInfo.version) build \(AppInfo.build)",
            "Device \(UIDevice.current.model) iOS \(UIDevice.current.systemVersion)",
            "Started \(ISO8601DateFormatter().string(from: Date()))",
            "Declared protocols: \(ExternalAccessoryTransport.declaredProtocols.joined(separator: ", "))"
        ])
        EAAccessoryManager.shared().registerForLocalNotifications()
        baselineInterfaces.value = Set(NetworkProbe.interfaces().map(\.summary))
        loadProfile()
        refreshAccessories()
        status = .disconnected
        message = "Not connected."

        if autoFcc {
            log("Auto-FCC enabled, connecting and applying")
            Task { await autoConnectAndApply() }
        }
    }

    private func loadProfile() {
        do {
            profile = try ProfileLoader.load(ProfileLoader.fccProfileName)
        } catch {
            log("Failed to load FCC profile: \(error.localizedDescription)")
        }
    }

    /// Re-reads the accessory list. Cheap, and the connect screen calls it on
    /// every EA connect and disconnect notification.
    func refreshAccessories() {
        let found = ExternalAccessoryTransport.connectedAccessories()
        let changed = found != accessories
        accessories = found
        guard changed else { return }
        if found.isEmpty {
            log("No MFi accessory visible to this app (0 of any manufacturer)")
        } else {
            for accessory in found {
                log("Accessory: \(accessory.manufacturer) \(accessory.modelNumber.isEmpty ? accessory.name : accessory.modelNumber)")
                log("  protocols: \(accessory.protocolStrings.joined(separator: ", "))")
                if !accessory.undeclaredProtocols.isEmpty {
                    log("  not declared in Info.plist: \(accessory.undeclaredProtocols.joined(separator: ", "))")
                }
            }
        }
    }

    /// Called when iOS reports the accessory went away under us.
    func accessoryDisconnected() {
        refreshAccessories()
        guard isConnected else { return }
        stopRepeat()
        transportBox.value?.close()
        transportBox.value = nil
        isConnected = false
        status = .disconnected
        message = "The accessory was unplugged."
        log("Accessory disconnected")
    }

    // MARK: Connect

    func connect() {
        guard !isConnected else { return }
        Task { await connectFlow(announce: true) }
    }

    private func autoConnectAndApply() async {
        try? await Task.sleep(for: .seconds(1))
        guard await connectFlow(announce: false) else { return }
        try? await Task.sleep(for: .milliseconds(500))
        enableFcc()
    }

    @discardableResult
    private func connectFlow(announce: Bool) async -> Bool {
        status = .connecting
        message = "Connecting to the controller..."
        if announce {
            log("Connecting to the controller...")
            log("First open DJI Fly so the drone links, then close it and plug into the TOP USB port.")
        }

        frameCensus.value = [:]
        let deadline = Date().addingTimeInterval(Self.connectTimeout)
        var warned = false

        while Date() < deadline {
            refreshAccessories()
            if let accessory = ExternalAccessoryTransport.preferredAccessory() {
                do {
                    log("Accessory advertises: \(accessory.protocolStrings.joined(separator: ", "))")
                    let transport = try ExternalAccessoryTransport(
                        accessory: accessory,
                        preferredProtocol: preferredProtocol.isEmpty ? nil : preferredProtocol
                    )
                    transport.keepaliveFraming = preferredPath.value.framing
                    transport.setFrameListener { [weak self] response in
                        self?.handleResponseOffMain(response)
                    }
                    transport.start()
                    transportBox.value = transport
                    transportName = transport.name
                    transportKind = transport.kind
                    protocolInUse = transport.protocolString
                    isConnected = true
                    status = .connected
                    message = "Connected. Ready to apply FCC."
                    log("Connected over \(transport.protocolString)")
                    sendBootstrap()
                    log("Bootstrap handshake sent")
                    startSerialPoll()
                    if isFccEnabled {
                        log("Resuming FCC repeat")
                        startRepeat()
                    }
                    return true
                } catch {
                    log(error.localizedDescription)
                    status = .disconnected
                    message = error.localizedDescription
                    isConnected = false
                    return false
                }
            }

            if !warned {
                warned = true
                log("No accessory yet, retrying for \(Int(Self.connectTimeout))s")
                log("If DJI Fly is holding the link, close it now")
            }
            try? await Task.sleep(for: .milliseconds(500))
        }

        status = .disconnected
        isConnected = false
        message = "Controller not found. Close DJI Fly, plug into the TOP USB port, then tap Connect."
        log("Connection failed, no DJI accessory detected")
        return false
    }

    /// Sends the 2-frame handshake that unlocks the command session.
    private func sendBootstrap() {
        guard let transport = transportBox.value else { return }
        for frame in Bootstrap.frames(framing: preferredPath.value.framing) {
            transport.write(frame)
        }
    }

    private func startSerialPoll() {
        serialPollTask?.cancel()
        serialPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                let found = self.transportBox.value?.detectedSerial ?? ""
                if !found.isEmpty, found != self.detectedSerial {
                    self.detectedSerial = found
                    self.log("Aircraft detected: \(found)")
                }
                if !self.isConnected { return }
            }
        }
    }

    // MARK: Apply

    /// True once the aircraft has been seen on the link.
    ///
    /// The serial only turns up in the telemetry the aircraft streams, and it
    /// streams nothing until the RC has re-linked to it. An apply with this
    /// false reaches the RC and stops there, which reads in the log exactly
    /// like FCC being refused, so it is worth calling out before wasting a
    /// physical test on it.
    var aircraftLinked: Bool { transportBox.value?.detectedSerial.isEmpty == false }

    func enableFcc() {
        guard requireConnection() else { return }
        if !aircraftLinked {
            log("WARNING: no aircraft telemetry yet. The RC has not re-linked to the drone.")
            log("Power the drone on, wait for the link, confirm the camera feed in DJI Fly, then retry.")
        }
        guard let profile else {
            log("FCC profile is missing from the bundle")
            return
        }
        status = .applying
        isBusy = true
        busyProgress = 0
        message = "Enabling FCC mode..."
        log("Enabling FCC mode...")

        let paths = commandPaths()
        engineQueue.async { [weak self] in
            self?.applyFccSync(profile: profile, paths: paths)
        }
    }

    /// The paths one apply sweeps, in the order they are tried.
    private func commandPaths() -> [CommandPath] {
        framingMode.framings.flatMap { framing in
            [Self.senderCapture, Self.senderNet0].map { CommandPath(sender: $0, framing: framing) }
        }
    }

    /// Blocks until the aircraft is seen on the link or the timeout passes.
    ///
    /// The serial only appears in the drone's own telemetry, so its presence
    /// is the one reliable "the RC is relaying to a drone" signal. Applying
    /// before it is up reaches the controller and stops there, which is the 0
    /// responses that read like a dead sequence. Waiting here is what makes an
    /// apply, manual or auto, land on the first try instead of the third.
    private nonisolated func waitForAircraft(timeoutMs: Int) -> Bool {
        if transportBox.value?.detectedSerial.isEmpty == false { return true }
        postLog("Waiting for the aircraft to link...")
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            if transportBox.value?.detectedSerial.isEmpty == false {
                postLog("Aircraft linked, applying now")
                return true
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return transportBox.value?.detectedSerial.isEmpty == false
    }

    private nonisolated func applyFccSync(profile: Profile, paths: [CommandPath]) {
        guard let transport = transportBox.value else {
            finishApply(anyWrite: false, acks: 0)
            return
        }

        if !waitForAircraft(timeoutMs: 20000) {
            postLog("No aircraft after 20s. Applying anyway, but expect no response until the drone is up.")
        }

        let framings = Array(Set(paths.map(\.framing)))
        let totalSends = paths.count * profile.rounds * profile.frames.count + framings.count
        let counter = Protected(0)

        postLog("Sweeping \(paths.count) path\(paths.count == 1 ? "" : "s") x \(profile.rounds) rounds @ \(profile.interFrameDelayMs)ms/frame")

        var anyWrite = false
        var best: (path: CommandPath, acks: Int)?

        for path in paths {
            armAckWatch(profile.frames.map { ($0.cmdSet << 8) | $0.cmdId })
            let wrote = sendPass(transport: transport, profile: profile, path: path) {
                let sent = counter.withLock { value -> Int in
                    value += 1
                    return value
                }
                self.postProgress(Double(sent) / Double(totalSends))
            }
            if wrote { anyWrite = true }
            let acks = readAckWatch(windowMs: profile.readWindowMs)
            postLog("\(path.label): \(acks) response\(acks == 1 ? "" : "s")")
            if acks > (best?.acks ?? 0) {
                best = (path, acks)
            }
        }

        // The WLM single-command switch goes last so it can never delay
        // service-mode entry for the profile passes.
        var wlmAcks = 0
        for framing in framings {
            armAckWatch([(0x51 << 8) | 0x04])
            let frame = DumplBuilder.buildFrame(
                DumplFrame(sender: Self.senderWlm, cmdType: 0x40, cmdSet: 0x51, cmdId: 0x04, dst: 0xEE)
            )
            if transport.write(RCLink.encode(frame, framing: framing, route: transport.currentRoute)) {
                anyWrite = true
            }
            let sent = counter.withLock { value -> Int in
                value += 1
                return value
            }
            postProgress(Double(sent) / Double(totalSends))
            let acks = readAckWatch(windowMs: profile.readWindowMs)
            wlmAcks += acks
            postLog("WLM 0x51/04/\(framing.label): \(acks) response\(acks == 1 ? "" : "s")")
        }

        if let best {
            preferredPath.value = best.path
            transport.keepaliveFraming = best.path.framing
            postLog("Controller answered on \(best.path.label), repeat will use that path")
            postWinner(best.path)
        } else if wlmAcks == 0 {
            postLog("No responses on any path. The controller is not relaying to the aircraft, which is not the same as FCC being rejected.")
        }

        let rx = transport.rxStats
        postLog("RX: \(rx.bytes) bytes, \(rx.framesDecoded) frames decoded")
        postLog("TX: \(rx.bytesWritten) of \(rx.bytesQueued) bytes actually written, \(rx.pumps) pumps")
        if rx.bytesWritten < rx.bytesQueued {
            postLog("Backlog of \(rx.bytesQueued - rx.bytesWritten) bytes never left the phone")
        }

        // How the far end frames what it sends is the best available guide to
        // how it expects to be spoken to.
        postLog("Inbound framing: \(rx.envelopes) RCLink envelopes, \(rx.bareFrames) bare frames, \(rx.skippedBytes) bytes skipped resyncing")
        postLog("First bytes on the link:")
        postLog(rx.previewHex)

        postLog("Census has \(frameCensus.value.count) distinct frame kinds. Dump Traffic for the full list.")
        if rx.framesDecoded == 0 && rx.bytes > 0 {
            // The link is carrying data the parser cannot make sense of, which
            // is a framing problem, not an aircraft that ignored us. The head
            // of the stream says which framing it actually is.
            postLog("Inbound bytes but no frame decoded. First bytes:")
            postLog(rx.previewHex)
        }
        finishApply(anyWrite: anyWrite, acks: (best?.acks ?? 0) + wlmAcks)
    }

    /// Unlocks the flight controller for parameter writes. Sent once per pass:
    /// sending it before every FLYCONTROLLER frame stretched the burst far
    /// past the service-mode window.
    private nonisolated func sendAssistantUnlock(transport: any DumplTransport, path: CommandPath) {
        let unlock = DumplBuilder.buildFrame(
            DumplFrame(sender: path.sender, cmdType: 0x40, cmdSet: 0x03, cmdId: 0xDF, dst: 0x03, payload: [0x01, 0x00, 0x00, 0x00])
        )
        transport.write(RCLink.encode(unlock, framing: path.framing, route: transport.currentRoute))
        Thread.sleep(forTimeInterval: 0.06)
    }

    /// Sends one self-contained pass: frame 1 opens service mode, frame 21
    /// closes it, everything between has to land inside that window.
    @discardableResult
    private nonisolated func sendPass(
        transport: any DumplTransport,
        profile: Profile,
        path: CommandPath,
        onFrameSent: (() -> Void)? = nil
    ) -> Bool {
        var anyWrite = false
        let route = transport.currentRoute
        sendAssistantUnlock(transport: transport, path: path)
        for _ in 0..<profile.rounds {
            for definition in profile.frames {
                let frame = ProfileLoader.buildFrame(definition, sender: path.sender, cmdType: profile.cmdType)
                if transport.write(RCLink.encode(frame, framing: path.framing, route: route)) {
                    anyWrite = true
                }
                onFrameSent?()
                if profile.interFrameDelay > 0 { Thread.sleep(forTimeInterval: profile.interFrameDelay) }
            }
            if profile.interRoundDelay > 0 { Thread.sleep(forTimeInterval: profile.interRoundDelay) }
        }
        return anyWrite
    }

    // MARK: Response accounting

    private nonisolated func armAckWatch(_ keys: [Int]) {
        ackKeys.value = Set(keys)
        ackHits.value = 0
    }

    private nonisolated func readAckWatch(windowMs: Int) -> Int {
        Thread.sleep(forTimeInterval: max(Double(windowMs), 50) / 1000)
        let hits = ackHits.value
        ackKeys.value = []
        return hits
    }

    /// Runs on the transport's IO thread, so it only touches the boxes.
    private nonisolated func handleResponseOffMain(_ response: DumplResponse) {
        let key = (response.sender << 24) | (response.dst << 16) | (response.cmdSet << 8) | response.cmdId
        frameCensus.withLock {
            var entry = $0[key] ?? (0, [])
            entry.count += 1
            entry.sample = response.payload
            $0[key] = entry
        }

        // The controller streams telemetry non-stop. Logging every frame buries
        // the useful lines, so only responses to commands we just sent count.
        guard response.isResponse, ackKeys.value.contains(response.ackKey) else { return }
        ackHits.withLock { $0 += 1 }
        if captureKeys.value.contains(response.ackKey) {
            captured.withLock { $0.append((response.ackKey, response.payload)) }
        }
        let payload = response.payload.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
        let suffix = payload.isEmpty ? "" : " [\(payload)]"
        postLog(String(
            format: "RSP %02X→%02X seq=%d set=%02X id=%02X%@",
            response.sender, response.dst, response.seq, response.cmdSet, response.cmdId, suffix
        ))
        // A config write/read reply on FLYCONTROLLER carries the value the drone
        // actually stored. Decoding it here makes an apply self-documenting: it
        // is how we saw max_height write 500 but store 120.
        if response.cmdSet == SpeedExperiment.flycSet, response.cmdId == AltitudeGate.writeByHash {
            postLog("    \(decodeEcho(response.payload))")
        }
    }

    // MARK: Repeat

    /// Re-sends the winning pass on an interval so the radio goes back to FCC
    /// after something resets it. Two resets get reported: DJI Fly
    /// reconnecting, and the aircraft dropping to CE the moment it sets its
    /// home point on GPS lock. Re-applying is the known remedy for both.
    private func startRepeat() {
        stopRepeat()
        guard let profile else { return }
        repeatCancelled.value = false
        let timer = DispatchSource.makeTimerSource(queue: engineQueue)
        let interval = Double(profile.repeatIntervalMs) / 1000
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.repeatTick(profile: profile)
        }
        timer.resume()
        repeatTimer = timer
    }

    private nonisolated func repeatTick(profile: Profile) {
        guard !repeatCancelled.value, let transport = transportBox.value, transport.isOpen else { return }
        let path = preferredPath.value
        sendPass(transport: transport, profile: profile, path: path)
        let wlm = DumplBuilder.buildFrame(
            DumplFrame(sender: Self.senderWlm, cmdType: 0x40, cmdSet: 0x51, cmdId: 0x04, dst: 0xEE)
        )
        transport.write(RCLink.encode(wlm, framing: path.framing, route: transport.currentRoute))
    }

    private func stopRepeat() {
        repeatCancelled.value = true
        repeatTimer?.cancel()
        repeatTimer = nil
    }

    // MARK: CE restore

    func disableFcc() {
        guard requireConnection() else { return }
        stopRepeat()
        status = .restoring
        isBusy = true
        busyProgress = 0
        message = "Restoring CE mode..."
        log("Restoring CE mode...")

        let framings = framingMode.framings
        engineQueue.async { [weak self] in
            guard let self else { return }
            do {
                let restore = try ProfileLoader.load(ProfileLoader.ceRestoreProfileName)
                self.restoreSync(profile: restore, framings: framings)
            } catch {
                self.postLog("CE restore failed: \(error.localizedDescription)")
                self.finishRestore(succeeded: false)
            }
        }
    }

    private nonisolated func restoreSync(profile: Profile, framings: [Framing]) {
        guard let transport = transportBox.value else {
            finishRestore(succeeded: false)
            return
        }
        var anyWrite = false
        // Restore on both sender bytes for the same reason apply sweeps both.
        for framing in framings {
            for sender in [profile.sender, Self.senderNet0] {
                for definition in profile.frames {
                    let frame = ProfileLoader.buildFrame(definition, sender: sender, cmdType: profile.cmdType)
                    if transport.write(RCLink.encode(frame, framing: framing, route: transport.currentRoute)) {
                        anyWrite = true
                    }
                    if profile.interFrameDelay > 0 { Thread.sleep(forTimeInterval: profile.interFrameDelay) }
                }
            }
        }
        finishRestore(succeeded: anyWrite)
    }

    // MARK: Release

    /// Closes the session without touching the radio state.
    ///
    /// iOS lets this app keep the session open in the background, so DJI Fly
    /// can usually run alongside it. When it cannot, this hands the link back
    /// without unplugging the cable; the radio keeps whatever region was last
    /// applied.
    func releaseSession() {
        stopRepeat()
        serialPollTask?.cancel()
        serialPollTask = nil
        transportBox.value?.close()
        transportBox.value = nil
        isConnected = false
        isBusy = false
        transportKind = ""
        transportName = ""
        protocolInUse = ""
        status = .released
        message = "Session released. Open DJI Fly now and check the Transmission tab."
        log("Session released, DJI Fly can connect now")
        log("Repeat stopped. If the radio flips back to CE, reconnect and re-apply.")
    }

    // MARK: Helpers

    private func requireConnection() -> Bool {
        if isConnected, transportBox.value != nil { return true }
        log("Connect to the controller first")
        return false
    }

    func clearLog() {
        logMessages = []
    }

    /// Whole log as one block, for the share sheet on the Log tab.
    var logExport: String {
        var lines = ["FCC Unlock iOS log"]
        if !transportName.isEmpty { lines.append("Transport: \(transportName)") }
        if !protocolInUse.isEmpty { lines.append("Protocol: \(protocolInUse)") }
        if !detectedSerial.isEmpty { lines.append("Aircraft: \(detectedSerial)") }
        if let winningPath { lines.append("Answered on: \(winningPath.label)") }
        for accessory in accessories {
            lines.append("Accessory: \(accessory.manufacturer) \(accessory.modelNumber) fw \(accessory.firmwareRevision)")
            lines.append("Protocols: \(accessory.protocolStrings.joined(separator: ", "))")
        }
        lines.append("")
        lines.append(contentsOf: logMessages.reversed())
        return lines.joined(separator: "\n")
    }

    // MARK: Diagnostics

    /// Reports what the phone can actually see, which is the question when
    /// Connect finds nothing.
    ///
    /// Two channels are checked, because iOS hides the first one from us
    /// unless we guessed right. `connectedAccessories` only ever returns
    /// accessories advertising a protocol string this build declared in
    /// Info.plist, so an empty list means either no MFi accessory at all or
    /// one speaking a string we did not declare, and nothing distinguishes
    /// those from inside the app. A new network interface, on the other hand,
    /// is visible whatever it calls itself: if the controller comes up as a
    /// USB network gadget the way the smart controllers do, it shows up here
    /// and needs no MFi programme membership to talk to.
    func runDiagnostics() {
        log("Diagnostics")
        log("  declared protocols: \(ExternalAccessoryTransport.declaredProtocols.joined(separator: ", "))")

        let accessories = ExternalAccessoryTransport.connectedAccessories()
        log("  MFi accessories visible: \(accessories.count)")
        for accessory in accessories {
            log("  - \(accessory.manufacturer) \(accessory.name) model \(accessory.modelNumber) fw \(accessory.firmwareRevision)")
            log("    protocols: \(accessory.protocolStrings.joined(separator: ", "))")
        }

        let interfaces = NetworkProbe.interfaces()
        let baseline = baselineInterfaces.value
        let fresh = interfaces.filter { !baseline.contains($0.summary) }
        log("  network interfaces: \(interfaces.count), new since launch: \(fresh.count)")
        for interface in interfaces where !interface.isLoopback {
            let marker = baseline.contains(interface.summary) ? " " : "*"
            log("  \(marker) \(interface.summary)")
        }

        let candidates = fresh.filter(\.isCandidate)
        guard !candidates.isEmpty else {
            log("  no new usable interface, so no USB network gadget appeared")
            return
        }
        log("  probing TCP \(NetworkProbe.djiCommandPort) on the new interfaces")
        engineQueue.async { [weak self] in
            for interface in candidates {
                for peer in NetworkProbe.candidatePeers(for: interface) {
                    let reachable = NetworkProbe.canReach(host: peer, port: NetworkProbe.djiCommandPort)
                    self?.postLog("  \(peer):\(NetworkProbe.djiCommandPort) \(reachable ? "OPEN" : "closed")")
                }
            }
            self?.postLog("  probe done")
        }
    }

    /// Hunts for a destination that answers the one command that matters.
    ///
    /// On an RC-N3 the profile splits cleanly in two: every peripheral write
    /// is acknowledged, and the frames that actually move the region are not.
    /// RADIO 6/114 sets the region and commits it, and GENERAL set 0 carries
    /// the country codes; those four frames draw no response while the
    /// fourteen around them do. A command that is simply refused would still
    /// answer, so silence points at the frame never reaching a component that
    /// handles it, which makes the destination byte the thing to vary.
    ///
    /// The destinations come from the census of who is actually talking on
    /// this link, plus the ones the profile already names. Both request types
    /// are tried, since a component that ignores a fire-and-forget request
    /// may still answer one that demands an acknowledgement.
    func probeRegionCommand() {
        guard requireConnection() else { return }
        log("Probing RADIO 6/114 across destinations")
        let destinations = [0x01, 0x02, 0x03, 0x04, 0x06, 0x07, 0x08, 0x09,
                            0x0A, 0x0E, 0x0F, 0x12, 0x1F, 0x20, 0x27, 0x28,
                            0x92, 0xE9, 0xEE]
        let payload: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00]
        engineQueue.async { [weak self] in
            guard let self, let transport = self.transportBox.value else { return }
            var hits = [String]()
            for cmdType in [0x20, 0x40] {
                for dst in destinations {
                    self.armAckWatch([(0x06 << 8) | 114])
                    let frame = DumplBuilder.buildFrame(
                        DumplFrame(sender: Self.senderNet0, cmdType: cmdType,
                                   cmdSet: 0x06, cmdId: 114, dst: dst, payload: payload)
                    )
                    transport.write(RCLink.encode(frame, framing: .rclink, route: transport.currentRoute))
                    let acks = self.readAckWatch(windowMs: 120)
                    if acks > 0 {
                        let line = String(format: "  dst %02X type %02X: %d responses", dst, cmdType, acks)
                        hits.append(line)
                        self.postLog(line)
                    }
                }
            }
            if hits.isEmpty {
                self.postLog("  no destination answered 6/114 on either request type")
                self.postLog("  the region command is not reaching anything that handles it")
            } else {
                self.postLog("  probe done, \(hits.count) destination(s) answered")
            }
        }
    }

    /// Prints everything the drone has been broadcasting, full payloads and
    /// all, sorted by how much it talks.
    ///
    /// Entirely passive. It sends nothing. The value is in the frames the
    /// aircraft emits on its own: a DUML link tends to broadcast its own state,
    /// so the RADIO set, especially the status push, is where the current
    /// region and power limits are most likely to be legible. Reading them is
    /// the ground truth the DJI Fly graph only hints at, and after an apply it
    /// is how we would see the region actually move.
    func dumpTraffic() {
        let census = frameCensus.value
        guard !census.isEmpty else {
            log("No traffic captured yet. Connect and wait a few seconds first.")
            return
        }
        log("Full inbound census, \(census.count) distinct frame kinds:")
        let sorted = census.sorted { $0.value.count > $1.value.count }
        for (key, entry) in sorted {
            let sender = (key >> 24) & 0xFF
            let dst = (key >> 16) & 0xFF
            let set = (key >> 8) & 0xFF
            let id = key & 0xFF
            let hex = entry.sample.prefix(24).map { String(format: "%02X", $0) }.joined(separator: " ")
            let flag = set == 0x06 ? " <-RADIO" : ""
            log(String(format: "  %02X->%02X set=%02X id=%02X x%d%@", sender, dst, set, id, entry.count, flag))
            if !hex.isEmpty { log("      [\(hex)]") }
        }
        // Call out the RADIO status push specifically, since that is the frame
        // most likely to carry the region byte.
        for (key, entry) in sorted where ((key >> 8) & 0xFF) == 0x06 {
            log(String(format: "RADIO frame set=06 id=%02X full payload:", key & 0xFF))
            log(entry.sample.map { String(format: "%02X", $0) }.joined(separator: " "))
        }
    }

    // MARK: Region, the documented way

    /// The RC and WiFi commands the DUML dissector documents for region,
    /// which are not the ones the ported profile uses.
    ///
    /// The profile sets region through RADIO 6/0x72, a command this RC-N3
    /// never answers. The dji-firmware-tools dissector names a different
    /// mechanism: RC 6/0x20 "RC Power Mode CE/FCC Set", its paired 6/0x21
    /// "Get", and WiFi 7/0x30 "Set Country Code", whose own comment says a
    /// country of "US" puts the RC into FCC and has it ask the aircraft to
    /// follow. The RC is device type 6.
    private enum Rc {
        static let set = 0x06
        static let powerModeSet = 0x20
        static let powerModeGet = 0x21
        static let deviceRC = 0x06

        static let wifiSet = 0x07
        static let setCountryCode = 0x30
    }

    /// Country code payload: str1(4) + str2(4) + unknown(2), per the dissector.
    private nonisolated static func countryPayload(_ code: String) -> [UInt8] {
        var field = Array(code.utf8.prefix(4))
        while field.count < 4 { field.append(0) }
        return field + field + [0x01, 0x00]
    }

    /// Reads the RC's current CE/FCC mode. Pure query, sends only a Get.
    ///
    /// This is the ground truth the DJI Fly graph only gestures at, and the
    /// first thing worth knowing: if 6/0x21 answers, the modern mechanism is
    /// alive on this firmware and its payload says which mode we are in.
    func readPowerMode() {
        guard requireConnection() else { return }
        log("Reading RC power mode (6/21 Get), pure query")
        engineQueue.async { [weak self] in
            guard let self, let transport = self.transportBox.value else { return }
            let key = (Rc.set << 8) | Rc.powerModeGet
            for dst in [Rc.deviceRC, 0x02, 0x09, 0x0E] {
                self.beginCapture([key])
                let frame = DumplBuilder.buildFrame(
                    DumplFrame(sender: Self.senderNet0, cmdType: 0x40,
                               cmdSet: Rc.set, cmdId: Rc.powerModeGet, dst: dst, payload: [])
                )
                transport.write(RCLink.encode(frame, framing: .rclink, route: transport.currentRoute))
                let hits = self.endCapture(windowMs: 150)
                for hit in hits {
                    let hex = hit.payload.map { String(format: "%02X", $0) }.joined(separator: " ")
                    self.postLog(String(format: "  dst %02X answered: [%@]", dst, hex))
                    if let first = hit.payload.first {
                        self.postLog("  -> mode byte \(first): \(first == 0 ? "CE" : "FCC")")
                    }
                }
                if hits.isEmpty { self.postLog(String(format: "  dst %02X: no answer", dst)) }
            }
            self.postLog("Read done")
        }
    }

    /// Applies FCC through the documented RC commands, then reads back to
    /// confirm rather than assuming.
    ///
    /// These are the commands DJI Fly itself sends every session, not pokes at
    /// unknown registers: set the country to US, set the RC power mode to FCC,
    /// then Get the mode and report what it actually is. RAM-only, so a power
    /// cycle undoes it.
    func applyFccRcMode() {
        guard requireConnection() else { return }
        status = .applying
        isBusy = true
        busyProgress = 0
        message = "Applying FCC through the RC power-mode commands..."
        log("Apply FCC (RC mode): country US + RC power mode FCC")
        engineQueue.async { [weak self] in self?.applyFccRcModeSync() }
    }

    private nonisolated func applyFccRcModeSync() {
        guard let transport = transportBox.value else { finishApply(anyWrite: false, acks: 0); return }
        let route = transport.currentRoute
        func send(_ set: Int, _ id: Int, dst: Int, _ payload: [UInt8], _ label: String) -> Int {
            beginCapture([(set << 8) | id])
            let frame = DumplBuilder.buildFrame(
                DumplFrame(sender: Self.senderNet0, cmdType: 0x40, cmdSet: set, cmdId: id, dst: dst, payload: payload)
            )
            transport.write(RCLink.encode(frame, framing: .rclink, route: route))
            let hits = endCapture(windowMs: 150)
            postLog("  \(label): \(hits.count) response\(hits.count == 1 ? "" : "s")")
            for hit in hits {
                let hex = hit.payload.map { String(format: "%02X", $0) }.joined(separator: " ")
                postLog("     [\(hex)]")
            }
            return hits.count
        }

        var answers = 0
        // Country US to the RC and to the destinations the profile used.
        let us = Self.countryPayload("US")
        for dst in [Rc.deviceRC, 0x09, 0x07] {
            answers += send(Rc.wifiSet, Rc.setCountryCode, dst: dst, us, String(format: "country US -> %02X", dst))
        }
        postProgress(0.4)
        // RC power mode = FCC (1) to the RC.
        for dst in [Rc.deviceRC, 0x02] {
            answers += send(Rc.set, Rc.powerModeSet, dst: dst, [0x01], String(format: "power FCC -> %02X", dst))
        }
        postProgress(0.7)
        // Read back.
        let confirm = send(Rc.set, Rc.powerModeGet, dst: Rc.deviceRC, [], "confirm Get")
        postProgress(1.0)
        postLog(confirm > 0 ? "Confirmed by read-back" : "No read-back, check Transmission")
        finishApply(anyWrite: true, acks: answers)
    }

    private nonisolated func beginCapture(_ keys: [Int]) {
        captureKeys.value = Set(keys)
        captured.value = []
        armAckWatch(keys)
    }

    private nonisolated func endCapture(windowMs: Int) -> [(key: Int, payload: [UInt8])] {
        Thread.sleep(forTimeInterval: max(Double(windowMs), 50) / 1000)
        let result = captured.value
        captureKeys.value = []
        captured.value = []
        ackKeys.value = []
        return result
    }

    // MARK: Experimental, speed parameters (read only for now)

    /// Reads the flight controller's attitude and altitude parameters, plus
    /// max_height as a self-check. Two phases: first it finds the read context
    /// that answers, using max_height (known to be 500 after an FCC apply) as a
    /// ground-truth probe across cmd_type and destination; then it reads every
    /// parameter on that context. It opens the same AUTOTEST service-mode plus
    /// assistant-unlock window an apply opens, but writes no flight parameter of
    /// its own: only Get Info (0xF7) and Read Value (0xF8) touch the config
    /// table, never Write (0xF9).
    ///
    /// The point of reading before writing: the info reply carries the min,
    /// max and default the firmware itself enforces, so a later speed change
    /// can stay inside bounds the flight controller already honours instead of
    /// guessing a number off a YouTube video.
    func probeSpeedParams() {
        guard requireConnection() else { return }
        if !aircraftLinked {
            log("WARNING: no aircraft linked. Readings will be empty until the drone is up.")
        }
        log("Experimental: reading attitude/speed parameters (read only)")
        engineQueue.async { [weak self] in self?.probeSpeedParamsSync() }
    }

    private nonisolated func probeSpeedParamsSync() {
        guard let transport = transportBox.value else { return }
        if !waitForAircraft(timeoutMs: 20000) {
            postLog("No aircraft linked. Reads will be empty.")
            return
        }

        // Read in the exact context an apply proved: the sender byte and the
        // framing the last sweep answered on (default 0x82 / RCLink, the
        // profile's own values). The earlier read probe hardcoded sender 0x02
        // and cmd_type 0x40 and held one service window open across every
        // parameter, roughly 3s; the profile's own timing note says a burst
        // stretched past a few seconds silently does nothing. This version
        // matches the proven sender/framing and keeps each read inside its own
        // tight service window.
        let path = preferredPath.value
        let route = transport.currentRoute
        postLog(String(format: "Reading in the proven apply context: sender %02X / %@",
                       path.sender, path.framing.label))

        func emit(_ set: Int, _ id: Int, dst: Int, cmdType: Int, _ payload: [UInt8]) {
            let frame = DumplBuilder.buildFrame(
                DumplFrame(sender: path.sender, cmdType: cmdType, cmdSet: set, cmdId: id, dst: dst, payload: payload)
            )
            transport.write(RCLink.encode(frame, framing: path.framing, route: route))
        }

        let flyc = SpeedExperiment.flycSet

        // The value portion of a read-value reply (status(1) + hash(4) + value).
        func replyValue(_ payload: [UInt8]) -> UInt32? {
            guard payload.count >= 6 else { return nil }
            let v = Array(payload[5...])
            if v.count >= 4 { return UInt32(v[0]) | (UInt32(v[1]) << 8) | (UInt32(v[2]) << 16) | (UInt32(v[3]) << 24) }
            if v.count == 2 { return UInt32(v[0]) | (UInt32(v[1]) << 8) }
            if v.count == 1 { return UInt32(v[0]) }
            return nil
        }

        // One tight service window: open exactly like profile frame 1
        // (AUTOTEST enter, cmd_type 0x20), assistant unlock (0x03/0xDF, the
        // 0x40 an apply uses), the read verbs for one parameter, then close.
        // The whole window runs in well under a second.
        func readInWindow(_ param: FlycParam, readCmdType: Int, dst: Int) -> (info: [UInt8]?, value: [UInt8]?) {
            emit(0x10, 0x58, dst: 0x12, cmdType: 0x20, [0x03, 0x01, 0x00])       // enter service mode
            Thread.sleep(forTimeInterval: 0.03)
            emit(0x03, 0xDF, dst: 0x03, cmdType: 0x40, [0x01, 0x00, 0x00, 0x00]) // assistant unlock
            Thread.sleep(forTimeInterval: 0.05)

            beginCapture([(flyc << 8) | SpeedExperiment.getInfoByHash])
            emit(flyc, SpeedExperiment.getInfoByHash, dst: dst, cmdType: readCmdType, param.hashLE)
            let info = endCapture(windowMs: 180).first?.payload

            beginCapture([(flyc << 8) | SpeedExperiment.readValueByHash])
            emit(flyc, SpeedExperiment.readValueByHash, dst: dst, cmdType: readCmdType, param.hashLE)
            let value = endCapture(windowMs: 180).first?.payload

            emit(0x10, 0x58, dst: 0x12, cmdType: 0x20, [0x03, 0x01, 0x00])       // exit service mode
            Thread.sleep(forTimeInterval: 0.05)
            return (info, value)
        }

        // Phase 1: find the read context using the self-check parameter, whose
        // value is known to be 500 after an FCC apply. Vary only the two
        // unknowns issue #2 points to: the read verb's cmd_type (the write path
        // answers on 0x20, not the 0x40 the old probe used) and the destination
        // the config responder lives behind (0x03, or the 0x92 SVO route the
        // proven fb-param writes use).
        let selfCheck = SpeedExperiment.params[0] // flying_limit.max_height
        postLog("Phase 1: finding the read context on \(selfCheck.name) (expect 500)")
        var winner: (readCmdType: Int, dst: Int)?
        outer: for readCmdType in [0x20, 0x40] {
            for dst in [0x03, 0x92] {
                let tag = String(format: "cmd_type %02X / dst %02X", readCmdType, dst)
                let r = readInWindow(selfCheck, readCmdType: readCmdType, dst: dst)
                if let value = r.value, let u = replyValue(value) {
                    let hex = value.map { String(format: "%02X", $0) }.joined(separator: " ")
                    postLog("  \(tag): value [\(hex)] -> \(u)")
                    if u == 500 {
                        postLog("  ✓ read context found: \(tag)")
                        winner = (readCmdType, dst)
                        break outer
                    }
                } else if let info = r.info {
                    let hex = info.map { String(format: "%02X", $0) }.joined(separator: " ")
                    postLog("  \(tag): info-only reply [\(hex)], no value")
                } else {
                    postLog("  \(tag): no reply")
                }
                Thread.sleep(forTimeInterval: 0.10)
            }
        }

        guard let winner else {
            postLog("No read context answered on any cmd_type/dst combination.")
            postLog("Any FLYCONTROLLER (set=03) frames seen inbound during the probe:")
            dumpFlycCensus()
            postLog("Next to try: whole-table read 0xFB, or send the read inside the same burst as a proven write.")
            return
        }

        // Phase 2: read every parameter on the winning context.
        postLog("Phase 2: reading all parameters on the winning context")
        for param in SpeedExperiment.params {
            postLog("• \(param.name)")
            postLog("  \(param.note)")
            let r = readInWindow(param, readCmdType: winner.readCmdType, dst: winner.dst)

            if let info = r.info, let parsed = ParamInfo(payload: info) {
                if parsed.status == 0 {
                    postLog("  type \(SpeedExperiment.typeName(parsed.typeId)) size \(parsed.size)")
                    postLog("  min \(parsed.minText)  max \(parsed.maxText)  default \(parsed.defText)")
                } else {
                    postLog("  info status \(parsed.status) (parameter not exposed here)")
                }
            } else {
                postLog("  no info reply")
            }

            if let value = r.value {
                let hex = value.map { String(format: "%02X", $0) }.joined(separator: " ")
                postLog("  current raw [\(hex)]")
                postLog("  \(interpretValue(value))")
            } else {
                postLog("  no value reply")
            }
            Thread.sleep(forTimeInterval: 0.08)
        }
        postLog("Experimental read done. Nothing was written to any parameter.")
    }

    /// Dumps the inbound frames tallied on the FLYCONTROLLER command set
    /// (0x03), so a partial or mis-keyed reply is still visible even when no
    /// read context matched the ack key. The census records every inbound
    /// frame, so this is the last word on whether the flight controller said
    /// anything at all on set 0x03 during a read.
    private nonisolated func dumpFlycCensus() {
        let census = frameCensus.value.filter { (($0.key >> 8) & 0xFF) == SpeedExperiment.flycSet }
        guard !census.isEmpty else {
            postLog("  (no set=03 frames seen at all)")
            return
        }
        for (key, entry) in census.sorted(by: { $0.value.count > $1.value.count }) {
            let sender = (key >> 24) & 0xFF
            let dst = (key >> 16) & 0xFF
            let id = key & 0xFF
            let hex = entry.sample.prefix(24).map { String(format: "%02X", $0) }.joined(separator: " ")
            postLog(String(format: "  %02X->%02X set=03 id=%02X x%d [%@]", sender, dst, id, entry.count, hex))
        }
    }

    // MARK: Experimental, altitude gate (issue #1, writes limit params)

    /// Hunts the parameter that gates the 500m altitude, by writing one limit
    /// candidate at a time and reading the value the drone actually stored from
    /// the write's own 0xF9 reply. This firmware answers the write verb with
    /// status + hash + stored value, but ignores the read verbs 0xF7/0xF8, so a
    /// write-and-read-back is the read channel we have.
    ///
    /// Writes are limit parameters only (altitude, distance, geo), the same
    /// class the FCC apply already writes. Restore CE or a power cycle resets
    /// them. It never writes a control or attitude parameter.
    func probeAltitudeGate() {
        guard requireConnection() else { return }
        if !aircraftLinked {
            log("WARNING: no aircraft linked. The probe needs the flight controller up.")
        }
        log("Experimental: altitude-gate probe (writes altitude/geo limits, reads the 0xF9 echo)")
        engineQueue.async { [weak self] in self?.probeAltitudeGateSync() }
    }

    private nonisolated func probeAltitudeGateSync() {
        guard let transport = transportBox.value else { return }
        if !waitForAircraft(timeoutMs: 20000) {
            postLog("No aircraft linked. Nothing to probe.")
            return
        }
        let path = preferredPath.value
        let route = transport.currentRoute
        postLog(String(format: "Altitude-gate probe in context sender %02X / %@", path.sender, path.framing.label))

        func emit(_ set: Int, _ id: Int, dst: Int, cmdType: Int, _ payload: [UInt8]) {
            let frame = DumplBuilder.buildFrame(
                DumplFrame(sender: path.sender, cmdType: cmdType, cmdSet: set, cmdId: id, dst: dst, payload: payload)
            )
            transport.write(RCLink.encode(frame, framing: path.framing, route: route))
        }

        let flyc = SpeedExperiment.flycSet
        let writeId = AltitudeGate.writeByHash

        // One tight service window: enter, unlock, write the candidate, read the
        // 0xF9 echo, exit. Same window discipline as the apply.
        func writeAndEcho(_ p: GateParam, dst: Int) -> [UInt8]? {
            emit(0x10, 0x58, dst: 0x12, cmdType: 0x20, [0x03, 0x01, 0x00])
            Thread.sleep(forTimeInterval: 0.03)
            emit(0x03, 0xDF, dst: 0x03, cmdType: 0x40, [0x01, 0x00, 0x00, 0x00])
            Thread.sleep(forTimeInterval: 0.05)
            beginCapture([(flyc << 8) | writeId])
            emit(flyc, writeId, dst: dst, cmdType: 0x20, p.hashLE + p.value)
            let echo = endCapture(windowMs: 200).first?.payload
            emit(0x10, 0x58, dst: 0x12, cmdType: 0x20, [0x03, 0x01, 0x00])
            Thread.sleep(forTimeInterval: 0.05)
            return echo
        }

        for p in AltitudeGate.candidates {
            let wrote = p.value.map { String(format: "%02X", $0) }.joined(separator: " ")
            postLog("• \(p.name)")
            postLog("  \(p.note)")
            postLog("  writing [\(wrote)] (\(p.value.count == 1 ? "u8" : "u16"))")

            var echo = writeAndEcho(p, dst: 0x03)
            if echo == nil { echo = writeAndEcho(p, dst: 0x92) } // also try the SVO route
            if let e = echo {
                let hex = e.map { String(format: "%02X", $0) }.joined(separator: " ")
                postLog("  echo [\(hex)]  \(decodeEcho(e))")
            } else {
                postLog("  no echo (parameter may not exist on this firmware)")
            }
            Thread.sleep(forTimeInterval: 0.08)
        }
        postLog("Altitude-gate probe done. Now open DJI Fly and check the altitude slider.")
        postLog("Any candidate whose write opens the slider past 120 is the gate. Restore CE / power cycle resets these writes.")
    }

    /// Decodes a config reply, status(1) + hash(4) + value(N), as the 0xF9 write
    /// and by-hash read commands return it.
    private nonisolated func decodeEcho(_ payload: [UInt8]) -> String {
        guard payload.count >= 5 else {
            return "status \(payload.first.map { String($0) } ?? "?"), no hash"
        }
        let status = payload[0]
        let hash = UInt32(payload[1]) | (UInt32(payload[2]) << 8) | (UInt32(payload[3]) << 16) | (UInt32(payload[4]) << 24)
        let v = Array(payload.dropFirst(5))
        var stored = "(none)"
        if v.count >= 4 {
            stored = "\(UInt32(v[0]) | (UInt32(v[1]) << 8) | (UInt32(v[2]) << 16) | (UInt32(v[3]) << 24))"
        } else if v.count == 2 {
            stored = "\(UInt16(v[0]) | (UInt16(v[1]) << 8))"
        } else if v.count == 1 {
            stored = "\(v[0])"
        }
        return String(format: "status %d  hash %08X  stored %@", status, hash, stored)
    }

    // MARK: Experimental, read via 0xFB (read only)

    /// Reads parameters with the `0xFB` verb (Read Params By Hash), the read
    /// command this firmware may still answer after 0xF7/0xF8 returned nothing.
    /// Pure read: it writes no parameter. This is the unblock for reading the
    /// authority/geo values (#1) and the attitude ranges plus bounds (#3).
    func probeReadFB() {
        guard requireConnection() else { return }
        if !aircraftLinked {
            log("WARNING: no aircraft linked. Reads will be empty.")
        }
        log("Experimental: reading parameters via 0xFB (read only)")
        engineQueue.async { [weak self] in self?.probeReadFBSync() }
    }

    private nonisolated func probeReadFBSync() {
        guard let transport = transportBox.value else { return }
        if !waitForAircraft(timeoutMs: 20000) {
            postLog("No aircraft linked. Nothing to read.")
            return
        }
        let path = preferredPath.value
        let route = transport.currentRoute
        let flyc = SpeedExperiment.flycSet
        let readId = ConfigRead.readMultiByHash
        postLog(String(format: "0xFB read in context sender %02X / %@", path.sender, path.framing.label))

        func emit(_ set: Int, _ id: Int, dst: Int, cmdType: Int, _ payload: [UInt8]) {
            let frame = DumplBuilder.buildFrame(
                DumplFrame(sender: path.sender, cmdType: cmdType, cmdSet: set, cmdId: id, dst: dst, payload: payload)
            )
            transport.write(RCLink.encode(frame, framing: path.framing, route: route))
        }

        // One tight service window per read: enter, unlock, 0xFB request, exit.
        // Request payload per the dissector: one flag byte then the 4-byte hash.
        func readOne(_ p: FlycParam, flag: UInt8, cmdType: Int, dst: Int) -> [UInt8]? {
            emit(0x10, 0x58, dst: 0x12, cmdType: 0x20, [0x03, 0x01, 0x00])
            Thread.sleep(forTimeInterval: 0.03)
            emit(0x03, 0xDF, dst: 0x03, cmdType: 0x40, [0x01, 0x00, 0x00, 0x00])
            Thread.sleep(forTimeInterval: 0.05)
            beginCapture([(flyc << 8) | readId])
            emit(flyc, readId, dst: dst, cmdType: cmdType, [flag] + p.hashLE)
            let reply = endCapture(windowMs: 200).first?.payload
            emit(0x10, 0x58, dst: 0x12, cmdType: 0x20, [0x03, 0x01, 0x00])
            Thread.sleep(forTimeInterval: 0.04)
            return reply
        }

        var anyReply = false
        for p in ConfigRead.params {
            postLog("• \(p.name)")
            postLog("  \(p.note)")
            var reply: [UInt8]?
            // Sweep flag byte, cmd_type and destination until one answers.
            outer: for flag: UInt8 in [0x01, 0x00] {
                for cmdType in [0x40, 0x20] {
                    for dst in [0x03, 0x92] {
                        if let r = readOne(p, flag: flag, cmdType: cmdType, dst: dst), !r.isEmpty {
                            reply = r
                            postLog(String(format: "  answered on flag %02X / cmd_type %02X / dst %02X", flag, cmdType, dst))
                            break outer
                        }
                    }
                }
            }
            if let r = reply {
                let hex = r.map { String(format: "%02X", $0) }.joined(separator: " ")
                postLog("  reply [\(hex)]  \(decodeEcho(r))")
                anyReply = true
            } else {
                postLog("  no reply on any flag/cmd_type/dst")
            }
            Thread.sleep(forTimeInterval: 0.06)
        }
        if !anyReply {
            postLog("0xFB returned nothing on this firmware either. The 0xF9 write-echo stays the only config channel.")
        }
        postLog("0xFB read done. Nothing was written.")
    }

    // MARK: Experimental, flight telemetry decode (read only)

    /// Decodes the latest OSD General (0x43) and Limit State (0x55) frames the
    /// flight controller has been pushing, so a Sport-mode flight shows real
    /// ground speed, height and flight mode. Reads only the census the app
    /// already collects; it sends nothing.
    func readTelemetry() {
        guard requireConnection() else { return }
        log("Experimental: decoding the latest flight telemetry")
        engineQueue.async { [weak self] in self?.readTelemetrySync() }
    }

    private nonisolated func readTelemetrySync() {
        let census = frameCensus.value
        func latest(_ set: Int, _ id: Int) -> [UInt8]? {
            census.first { (($0.key >> 8) & 0xFF) == set && ($0.key & 0xFF) == id }?.value.sample
        }
        guard let osd = latest(SpeedExperiment.flycSet, 0x43) else {
            postLog("No OSD (0x43) frame captured yet. Fly for a moment, then read again.")
            return
        }
        let hex = osd.prefix(32).map { String(format: "%02X", $0) }.joined(separator: " ")
        postLog("OSD General (0x43) sample: [\(hex)]")
        if let h = OsdGeneral.heightMeters(osd) { postLog(String(format: "  height %.1f m", h)) }
        if let kmh = OsdGeneral.horizontalKmh(osd) { postLog(String(format: "  ground speed %.1f km/h", kmh)) }
        if let tilt = OsdGeneral.tiltDegrees(osd) { postLog(String(format: "  tilt %.1f°", tilt)) }
        postLog("  flight mode \(OsdGeneral.flightMode(osd))")
        if osd.allSatisfy({ $0 == 0 }) {
            postLog("  (all zero: the drone was on the ground / not armed when captured)")
        }
        if let limit = latest(SpeedExperiment.flycSet, 0x55) {
            let lhex = limit.map { String(format: "%02X", $0) }.joined(separator: " ")
            postLog("Limit State (0x55) sample: [\(lhex)]")
        }
        postLog("Telemetry read done.")
    }

    /// Continuous, passive flight recorder. Samples the OSD frame the flight
    /// controller already streams and tracks the peak horizontal speed and
    /// height over a window, so a Sport-mode flight yields a real measured km/h
    /// without DJI Fly, whose reconnect resets our runtime writes. It writes
    /// nothing: it only reads the census the app already collects, on its own
    /// queue so the link-hold timer is untouched.
    func recordFlight(seconds: Int = 30) {
        guard requireConnection() else { return }
        log("Experimental: recording flight telemetry for \(seconds)s (passive, reads only)")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.recordFlightSync(seconds: seconds)
        }
    }

    private nonisolated func recordFlightSync(seconds: Int) {
        func latestOsd() -> [UInt8]? {
            frameCensus.value.first {
                (($0.key >> 8) & 0xFF) == SpeedExperiment.flycSet && ($0.key & 0xFF) == 0x43
            }?.value.sample
        }
        guard latestOsd() != nil else {
            postLog("No OSD (0x43) frame yet. Make sure the drone is linked, then start again.")
            return
        }
        postLog("Recording. Fly Sport, full stick forward, in open space. Peaks appear below.")
        var peakKmh = 0.0
        var peakHeight = 0.0
        var peakTilt = 0.0
        var tiltAtPeak: Double?
        var samples = 0
        var lastLog = Date.distantPast
        let deadline = Date().addingTimeInterval(Double(seconds))
        while Date() < deadline {
            if let osd = latestOsd(), !osd.allSatisfy({ $0 == 0 }) {
                samples += 1
                let tilt = OsdGeneral.tiltDegrees(osd)
                if let kmh = OsdGeneral.horizontalKmh(osd), kmh > peakKmh {
                    peakKmh = kmh
                    tiltAtPeak = tilt
                    postLog(String(format: "  new peak %.1f km/h  tilt %.1f°  mode %@", kmh, tilt ?? 0, OsdGeneral.flightMode(osd)))
                }
                if let h = OsdGeneral.heightMeters(osd), h > peakHeight { peakHeight = h }
                if let tilt, tilt > peakTilt { peakTilt = tilt }
                if Date().timeIntervalSince(lastLog) > 2 {
                    lastLog = Date()
                    let now = OsdGeneral.horizontalKmh(osd) ?? 0
                    let h = OsdGeneral.heightMeters(osd) ?? 0
                    postLog(String(format: "  now %.1f km/h, %.1f m, tilt %.1f°, mode %@", now, h, tilt ?? 0, OsdGeneral.flightMode(osd)))
                }
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        postLog("Recording done.")
        postLog(String(format: "PEAK horizontal speed %.1f km/h,  PEAK height %.1f m,  %d live samples", peakKmh, peakHeight, samples))
        if let tiltAtPeak {
            postLog(String(format: "Tilt at the speed peak %.1f°, highest tilt seen %.1f°", tiltAtPeak, peakTilt))
        }
        if peakKmh <= 0 {
            postLog("Peak stayed 0. Either the OSD speed field is not updating over this link, or the drone did not move while recording.")
            return
        }
        if peakKmh < 30 {
            postLog("Under ~30 km/h: the Sport cap (28.8) still holds.")
        } else {
            postLog("Above the 28.8 Sport cap: the boost moved the limit. Note the number and the tilt.")
        }
        // The tilt flown against the tilt stored tells the two possible caps apart.
        guard let stored = sportTiltStored.value else {
            postLog("No Sport tilt was confirmed stored in this session, so there is nothing to compare the flown tilt with. Run Boost Sport Speed first.")
            return
        }
        guard let tiltAtPeak else { return }
        if tiltAtPeak < Double(stored) - 5 {
            postLog(String(format: "The drone leaned %.1f° of the %.1f° it stores: the tilt is not what holds it back. A separate velocity limit caps Sport, so raising the tilt further will not help.", tiltAtPeak, stored))
        } else {
            postLog(String(format: "The drone leaned %.1f°, close to the %.1f° it stores: speed is tilt-limited, so the stored tilt is the lever.", tiltAtPeak, stored))
        }
    }

    /// Warmth check. Writes max_height, the value the FCC apply already sets, and
    /// looks for its 0xF9 echo. That echo only comes back when the controller is
    /// relaying to the aircraft, so max_height doubles as a link-warmth sensor:
    /// it echoes when warm, nothing when cold. This removes the ambiguity where a
    /// cold link and a wrong write both look like "no echo".
    private nonisolated func linkIsWarm() -> Bool {
        guard let transport = transportBox.value else { return false }
        let path = preferredPath.value
        let route = transport.currentRoute
        func emit(_ set: Int, _ id: Int, dst: Int, cmdType: Int, _ p: [UInt8]) {
            transport.write(RCLink.encode(
                DumplBuilder.buildFrame(DumplFrame(sender: path.sender, cmdType: cmdType, cmdSet: set, cmdId: id, dst: dst, payload: p)),
                framing: path.framing, route: route))
        }
        emit(0x10, 0x58, dst: 0x12, cmdType: 0x20, [0x03, 0x01, 0x00])
        Thread.sleep(forTimeInterval: 0.03)
        emit(0x03, 0xDF, dst: 0x03, cmdType: 0x40, [0x01, 0x00, 0x00, 0x00])
        Thread.sleep(forTimeInterval: 0.05)
        beginCapture([(SpeedExperiment.flycSet << 8) | SportBoost.writeByHash])
        emit(SpeedExperiment.flycSet, SportBoost.writeByHash, dst: 0x03, cmdType: 0x20,
             [0x8a, 0x23, 0x71, 0x03, 0xf4, 0x01]) // max_height = 500, echoes 120 when warm
        let warm = endCapture(windowMs: 220).contains {
            $0.payload.count >= 5 && $0.payload[1] == 0x8a && $0.payload[2] == 0x23 && $0.payload[3] == 0x71
        }
        emit(0x10, 0x58, dst: 0x12, cmdType: 0x20, [0x03, 0x01, 0x00])
        Thread.sleep(forTimeInterval: 0.04)
        return warm
    }

    // MARK: Experimental, Sport-speed boost (issue #3, writes control params)

    /// Raises the Sport block's max tilt, which sets Sport top speed on
    /// Mavic-generation firmware, and reads back what the drone stored. Each
    /// Sport-block name is written with 0xF9 and its echo decoded: a bare
    /// `[00]` means the name is not on this firmware, a stored value below the
    /// written one means the flight controller clamped it to its own ceiling.
    /// Silence means neither, so after a silence the link warmth is checked
    /// again and a cold link stops the run with the rest marked untested.
    /// Ground only, one run at a time.
    func applySpeedBoost() {
        guard requireConnection(), beginSportRun() else { return }
        if !aircraftLinked {
            log("WARNING: no aircraft linked. Writes will not land.")
        }
        log("Experimental: Sport-speed boost (writes the Sport flight-control block)")
        engineQueue.async { [weak self] in self?.applySpeedBoostSync() }
    }

    private func beginSportRun() -> Bool {
        let started = sportRunning.withLock { running -> Bool in
            guard !running else { return false }
            running = true
            return true
        }
        if !started { log("A Sport-block run is already in progress. Wait for it to finish.") }
        return started
    }

    private nonisolated func applySpeedBoostSync() {
        defer { sportRunning.value = false }
        guard sportPreflight(action: "Nothing written") else { return }
        postLog("Link is WARM. Writing the Sport block (32-bit floats).")
        postLog("Flight-safety: test low and slow in open space. A power cycle may not undo it.")

        // 0xFA got no reply on any name (Neo, 12 Sep 2026), so the stock tilt
        // cannot be read and the fallback is written. The writes run alone and
        // first: the link stays warm only about half a minute after DJI Fly.
        let tilt = SportBoost.tiltTarget(stock: nil) ?? SportBoost.fallbackTilt
        var present = 0
        var bare = 0
        var silent = 0
        var clamped = false
        var untested: [String] = []
        for (index, p) in SportBoost.params.enumerated() {
            let value = p.kind == .tilt ? tilt : SportBoost.rcScale
            postLog(String(format: "• %@  (hash %08X)  writing %.2f", p.name, p.hash, value))
            guard let reply = byHashInWindow(SportBoost.writeByHash, p.hashLE + SportBoost.f32(value)) else {
                // Silence is not absence: find out whether the link just went cold.
                if linkIsWarm() {
                    silent += 1
                    postLog("  no reply on a warm link: unknown, not absent")
                    continue
                }
                untested = SportBoost.params[index...].map(\.name)
                postLog("  no reply, and the link has gone cold: this name and the ones after it are untested")
                break
            }
            guard let echo = ParamEcho(reply), echo.hash == p.hash else {
                bare += 1
                postLog("  \(describeSportReply(reply)): bare reply, this name is not in the firmware's table. Nothing stored.")
                continue
            }
            present += 1
            guard let stored = echo.float else {
                postLog("  \(describeSportReply(reply)): the stored value is not a 4-byte float, check the width")
                continue
            }
            if abs(stored - value) < 0.01 {
                postLog(String(format: "  ACCEPTED, the drone stores %.2f", stored))
            } else if stored < value {
                clamped = true
                postLog(String(format: "  CLAMPED, the drone stores %.2f: that is this firmware's ceiling for the parameter", stored))
            } else {
                postLog(String(format: "  the drone stores %.2f, not the %.2f written", stored, value))
            }
            if p.kind == .tilt { sportTiltStored.value = stored }
            Thread.sleep(forTimeInterval: 0.08)
        }

        if !untested.isEmpty {
            postLog("The link went cold mid-run. Untested, not absent: \(untested.joined(separator: ", ")).")
            postLog("Open DJI Fly to the LIVE CAMERA, close it, connect, and tap Boost straight away, before the FCC apply.")
        }
        if present > 0 {
            if clamped {
                postLog("Stored, but clamped. The firmware caps the Sport block below the requested value, so this is as far as parameters go. Record a Sport flight to measure what the clamped value gives.")
            } else {
                postLog("Boost stored. Now tap Record Sport Flight and fly Sport, full stick, low, in open space. The recorder compares the tilt flown with the tilt stored.")
            }
        } else if untested.isEmpty && silent == 0 {
            postLog("Every Sport-block name got a bare reply: none exists on this firmware. Neither the old globals nor the Mavic-generation block are here; the Neo's own table is needed (issue #3). Nothing was stored.")
        } else if untested.isEmpty {
            postLog("\(silent) name(s) got no reply on a warm link and \(bare) a bare reply. Inconclusive: run it again.")
        }
    }

    /// Sends a 0xFA reset on every Sport-block name and decodes the replies.
    /// On the Neo 0xFA has not answered so far, so the restore is unconfirmed
    /// there; only a name that echoed ACCEPTED in a boost was ever changed.
    /// Ground only, one run at a time.
    func restoreSportDefaults() {
        guard requireConnection(), beginSportRun() else { return }
        log("Experimental: restoring the Sport block to stock")
        engineQueue.async { [weak self] in self?.restoreSportDefaultsSync() }
    }

    private nonisolated func restoreSportDefaultsSync() {
        defer { sportRunning.value = false }
        guard sportPreflight(action: "Nothing restored") else { return }
        var confirmed = 0
        for p in SportBoost.params {
            postLog("• \(p.name)")
            if let reply = byHashInWindow(SportBoost.resetByHash, p.hashLE) {
                postLog("  reset: \(describeSportReply(reply))")
                if let echo = ParamEcho(reply), echo.hash == p.hash { confirmed += 1 }
            } else {
                postLog("  reset: no reply")
            }
            Thread.sleep(forTimeInterval: 0.08)
        }
        if confirmed > 0 { sportTiltStored.value = nil }
        postLog("Restore done, \(confirmed) reset(s) confirmed by the parameter's hash. With none confirmed the reset is unknown; only a name that echoed ACCEPTED in a boost was ever changed.")
    }

    /// The checks both Sport-block writers run first: aircraft linked, on the
    /// ground, link warm. Logs why it refused and returns false.
    private nonisolated func sportPreflight(action: String) -> Bool {
        if !waitForAircraft(timeoutMs: 20000) {
            postLog("No aircraft linked. \(action).")
            return false
        }
        guard aircraftOnGround() else {
            postLog("The drone is flying. Land it first: this writes flight-control parameters. \(action).")
            return false
        }
        let path = preferredPath.value
        postLog(String(format: "Sport block in context sender %02X / %@", path.sender, path.framing.label))
        postLog("Checking link warmth (max_height echo)...")
        guard linkIsWarm() else {
            postLog("Link is COLD: max_height did not echo, so the controller is not relaying to the aircraft.")
            postLog("Reconnecting the controller is not enough. Open DJI Fly, wait for the LIVE CAMERA image, close it, connect, then tap straight away: the link stays warm about half a minute. \(action).")
            return false
        }
        return true
    }

    /// Whether the latest OSD push says the aircraft is on the ground: all
    /// zero (not armed), or under 1 km/h within 1 m of the take-off height.
    /// True when no OSD has arrived yet, so a bench session is not blocked;
    /// the warmth gate still refuses a cold link.
    private nonisolated func aircraftOnGround() -> Bool {
        let osd = frameCensus.value.first {
            (($0.key >> 8) & 0xFF) == SpeedExperiment.flycSet && ($0.key & 0xFF) == 0x43
        }?.value.sample
        guard let osd, !osd.allSatisfy({ $0 == 0 }) else { return true }
        let kmh = OsdGeneral.horizontalKmh(osd) ?? 0
        let height = OsdGeneral.heightMeters(osd) ?? 0
        return kmh < 1 && abs(height) < 1
    }

    /// Sends one by-hash FLYC command inside its own tight service window and
    /// returns the reply carrying the same hash, else the first reply to that
    /// command, else nil. Tries dst 0x03, then the SVO route 0x92.
    private nonisolated func byHashInWindow(_ cmdId: Int, _ payload: [UInt8]) -> [UInt8]? {
        guard let transport = transportBox.value else { return nil }
        let path = preferredPath.value
        let route = transport.currentRoute
        let flyc = SpeedExperiment.flycSet
        let hashLE = Array(payload.prefix(4))
        func emit(_ set: Int, _ id: Int, dst: Int, cmdType: Int, _ p: [UInt8]) {
            transport.write(RCLink.encode(
                DumplBuilder.buildFrame(DumplFrame(sender: path.sender, cmdType: cmdType, cmdSet: set, cmdId: id, dst: dst, payload: p)),
                framing: path.framing, route: route))
        }
        for dst in [0x03, 0x92] {
            emit(0x10, 0x58, dst: 0x12, cmdType: 0x20, [0x03, 0x01, 0x00])
            Thread.sleep(forTimeInterval: 0.03)
            emit(0x03, 0xDF, dst: 0x03, cmdType: 0x40, [0x01, 0x00, 0x00, 0x00])
            Thread.sleep(forTimeInterval: 0.05)
            beginCapture([(flyc << 8) | cmdId])
            emit(flyc, cmdId, dst: dst, cmdType: 0x20, payload)
            let replies = endCapture(windowMs: 200).map(\.payload)
            emit(0x10, 0x58, dst: 0x12, cmdType: 0x20, [0x03, 0x01, 0x00])
            Thread.sleep(forTimeInterval: 0.05)
            if let match = replies.first(where: { $0.count >= 5 && Array($0[1...4]) == hashLE }) { return match }
            if let first = replies.first { return first }
        }
        return nil
    }

    /// A Sport-block reply for the log: raw bytes, then status, hash and the
    /// stored value as a float when it is one.
    private nonisolated func describeSportReply(_ raw: [UInt8]) -> String {
        let hex = raw.map { String(format: "%02X", $0) }.joined(separator: " ")
        guard let echo = ParamEcho(raw) else {
            return "[\(hex)]  status \(raw.first.map { String($0) } ?? "?"), no hash"
        }
        if let value = echo.float {
            return String(format: "[%@]  status %d  hash %08X  stored %.2f", hex, echo.status, echo.hash, value)
        }
        return "[\(hex)]  \(decodeEcho(raw))"
    }

    /// Best-effort human reading of a read-value reply. The reply is
    /// status + hash + value; the value's width is whatever the parameter is,
    /// so this shows it as int and as float and lets the eye pick the sensible
    /// one.
    private nonisolated func interpretValue(_ payload: [UInt8]) -> String {
        // status(1) + hash(4) + value(N)
        guard payload.count > 5 else { return "value: (short)" }
        let value = Array(payload[5...])
        func u32(_ b: [UInt8]) -> UInt32 {
            var v: UInt32 = 0
            for (i, byte) in b.prefix(4).enumerated() { v |= UInt32(byte) << (8 * i) }
            return v
        }
        if value.count >= 4 {
            let u = u32(value)
            return "value: uint \(u)  int \(Int32(bitPattern: u))  float \(String(format: "%.3f", Float(bitPattern: u)))"
        }
        if value.count == 2 {
            let u = UInt16(value[0]) | (UInt16(value[1]) << 8)
            return "value: \(u)"
        }
        if value.count == 1 { return "value: \(value[0])" }
        return "value: (empty)"
    }

    private func log(_ text: String) {
        let stamp = Self.timeFormatter.string(from: Date())
        let entry = "[\(stamp)] \(text)"
        logMessages.insert(entry, at: 0)
        if logMessages.count > 200 { logMessages.removeLast(logMessages.count - 200) }
        // Also to the unified log and the container file, so a run on real
        // hardware can be read back after the fact instead of retyped.
        DiagnosticLog.shared.append(entry)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    // MARK: Hops back to the main actor

    private nonisolated func postLog(_ text: String) {
        Task { @MainActor [weak self] in self?.log(text) }
    }

    private nonisolated func postProgress(_ value: Double) {
        Task { @MainActor [weak self] in self?.busyProgress = min(max(value, 0), 1) }
    }

    private nonisolated func postWinner(_ path: CommandPath) {
        Task { @MainActor [weak self] in self?.winningPath = path }
    }

    /// Reports the outcome without inflating it.
    ///
    /// Writes reaching the transport is not the aircraft accepting anything.
    /// Treating the two as the same is how an app ends up showing a green FCC
    /// badge over a radio that never left CE, so a silent sweep gets its own
    /// state rather than borrowing the successful one.
    private nonisolated func finishApply(anyWrite: Bool, acks: Int) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isBusy = false
            self.busyProgress = acks > 0 ? 1 : 0
            if acks > 0 {
                self.status = .fccEnabled
                self.isFccEnabled = true
                self.message = "FCC applied and the controller answered. Check Transmission in DJI Fly."
                self.log("FCC applied, starting repeat to hold it")
                self.startRepeat()
            } else if anyWrite && self.aircraftLinked {
                // The aircraft is on the link and the frames went out. This
                // firmware answers no region Get, so the graph is the only
                // confirmation, and the pass that takes often lands a few
                // seconds later once the link fully settles. Hold automatically
                // and keep re-applying rather than asking for a manual tap.
                self.status = .fccEnabled
                self.isFccEnabled = true
                self.busyProgress = 1
                self.message = "FCC sequence applied and held. Verify in DJI Fly Transmission: the signal should reach past 1km."
                self.log("Applied with the aircraft linked, holding by re-applying (region cannot be read back here)")
                self.startRepeat()
            } else if anyWrite {
                self.status = .sentUnconfirmed
                self.isFccEnabled = false
                self.message = "Sent, but no aircraft on the link. Power the drone on, wait for the link, then apply again."
                self.log("Sent with no aircraft linked, not holding")
            } else {
                self.status = .connected
                self.message = "FCC apply failed. Is the aircraft powered on and linked?"
                self.log("FCC apply failed, no frame reached the transport")
            }
        }
    }

    /// Starts the re-apply loop on the user's say-so, for the case where the
    /// radio took the sequence without answering it.
    func holdFcc() {
        guard requireConnection() else { return }
        isFccEnabled = true
        status = .fccEnabled
        message = "Holding FCC by re-applying on an interval."
        log("Hold requested, starting repeat despite no responses")
        startRepeat()
    }

    private nonisolated func finishRestore(succeeded: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isBusy = false
            self.status = .connected
            if succeeded {
                self.isFccEnabled = false
                self.message = "CE mode restored"
                self.log("CE mode restored")
            } else {
                self.message = "CE restore failed"
                self.log("CE restore failed")
            }
        }
    }
}
